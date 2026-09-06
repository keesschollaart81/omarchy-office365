#!/usr/bin/env python3
"""Microsoft Graph helper for the Omarchy Office 365 plugin.

Stdlib only, so the plugin has nothing to install. Speaks the OAuth 2.0
device-code flow (public client, no secret) and returns JSON on stdout for
the QML side to render.

Subcommands:
  login-start   begin a device-code login, print the user code + URL
  login-poll    poll once for completion of a pending login
  fetch         refresh silently and return recent mail + calendar events
  list          list configured accounts
  message       fetch one message with its body, for the reading pane
  mark          mark a message read or unread (needs write access)
  delete        move a message to Deleted Items (needs write access)
  remove        forget an account's tokens

Every command prints a single JSON object. Failures are reported as
{"ok": false, "error": {...}} with exit code 0 unless the arguments
themselves were unusable, so the widget always has something to render.
"""

import argparse
import json
import os
import re
import stat
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

# Default app registration: "Omarchy Office 365 Mail & Calendar", in the
# schollaart.net tenant. Multi-tenant and personal-account enabled, public
# client, no secret - a client id in a device-code public-client flow is an
# identifier rather than a secret, which is why one can ship in the open.
#
# Published by a verified publisher (Case Online), so consent shows the
# verified badge and tenants that block unverified apps still accept it.
#
# Organizations that would rather own the registration themselves - for consent
# control, conditional access, or auditing - set "clientId" per mailbox in
# shell.json.
DEFAULT_CLIENT_ID = "1cebbbf2-9896-4381-b471-0b6740eb6748"

# "common" accepts both work/school and personal Microsoft accounts, so one
# login button serves every account type.
DEFAULT_AUTHORITY = "common"

# Read-only by default. Write access is requested only when the user turns on
# something that needs it, and then only for that mailbox - a mail widget has
# no business holding permission to delete mail it was never asked to touch.
SCOPES_READ = "openid profile offline_access User.Read Mail.Read Calendars.Read"
SCOPES_WRITE = "openid profile offline_access User.Read Mail.ReadWrite Calendars.Read"


def scopes_for(write):
    return SCOPES_WRITE if write else SCOPES_READ
GRAPH = "https://graph.microsoft.com/v1.0"
USER_AGENT = "omarchy-office365-plugin/1.0"

STATE_DIR = os.path.join(
    os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
    "omarchy",
    "office365",
)


# --------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------


def out(payload):
    json.dump(payload, sys.stdout)
    sys.stdout.write("\n")
    sys.stdout.flush()


def fail(code, message, **extra):
    out({"ok": False, "error": dict(code=code, message=message, **extra)})
    sys.exit(0)


class AccountError(Exception):
    """A failure that belongs to one mailbox.

    Fetching several mailboxes must not be all-or-nothing: one expired refresh
    token cannot be allowed to empty the other accounts' mail and calendar, so
    per-account problems are raised and caught per account instead of ending
    the process.
    """

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


# An alias is both the name a mailbox goes by in shell.json and the name of the
# file its tokens live in, so the two have to map one-to-one. Dropping
# unsupported characters does not: `work/a`, `work!a` and `worka` would all land
# on worka.json and silently share one set of tokens, so fetching, marking or
# deleting through one alias could reach into another mailbox. Rejecting is the
# only safe answer - the worst case becomes an error message rather than the
# wrong mailbox.
ALIAS_ALLOWED = re.compile(r"\A[A-Za-z0-9._-]+\Z")


def alias_problem(alias):
    """Why this alias cannot name a token file, or "" if it can."""
    value = str(alias or "").strip()
    if not value:
        return "An account alias is required"
    if not ALIAS_ALLOWED.match(value):
        return ("Account alias may only contain letters, digits, dot, dash and "
                "underscore, so that each alias has tokens of its own")
    if not any(c.isalnum() for c in value):
        return "Account alias must contain letters or digits"
    return ""


def state_path(alias, kind="account"):
    problem = alias_problem(alias)
    if problem:
        # An AccountError rather than an exit: one badly named mailbox must not
        # be able to empty the other mailboxes in the same fetch.
        raise AccountError("bad_alias", problem)
    safe = str(alias).strip()
    name = f"{safe}.json" if kind == "account" else f"{safe}.{kind}.json"
    return os.path.join(STATE_DIR, name)


def read_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


def write_json(path, data):
    """Write private state (tokens) so only the user can read it."""
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, stat.S_IRUSR | stat.S_IWUSR)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle)
    os.replace(tmp, path)


def local_timezone():
    """IANA zone name, so Graph can return event times already localized."""
    link = "/etc/localtime"
    try:
        if os.path.islink(link):
            target = os.path.realpath(link)
            for marker in ("/zoneinfo/", "/zoneinfo.default/"):
                if marker in target:
                    return target.split(marker, 1)[1]
    except OSError:
        pass
    for path in ("/etc/timezone", os.path.expanduser("~/.config/timezone")):
        value = None
        try:
            with open(path, "r", encoding="utf-8") as handle:
                value = handle.read().strip()
        except OSError:
            continue
        if value:
            return value
    return "UTC"


def local_zone(name):
    """The named zone itself, not the offset it happens to be at today.

    A calendar window is built by adding days to midnight, and the offset in
    force on the last of those days need not be the one in force now. Asking
    for three days from 24 October in Europe/Amsterdam with today's +02:00
    gives an end of 27 October at +02:00 - which is 23:00 on the 26th, so the
    last hour of the range is silently missing. A ZoneInfo works out the offset
    for each wall-clock time it is given, so both ends land on local midnight.
    """
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError, OSError):
        # An unusable zone name leaves the system's current offset, which is
        # what this did before and is still better than pretending it is UTC.
        return datetime.now().astimezone().tzinfo


# Nothing Graph legitimately answers with comes close to this, and the widget
# holds whatever arrives in memory inside the shared shell process. An
# unbounded read trusts the far end to be reasonable about length; a cap costs
# nothing and means a wrong or hostile answer cannot grow without limit.
MAX_RESPONSE_BYTES = 16 * 1024 * 1024


def read_capped(response, limit=MAX_RESPONSE_BYTES):
    """The body, up to `limit` bytes. A longer one is cut, not swallowed whole.

    Reading one byte past the cap is what tells us it was too long: the JSON
    then fails to parse and the caller reports a failure, which is the right
    outcome for a response we cannot trust the shape of anyway.
    """
    return response.read(limit + 1)[:limit].decode("utf-8", "replace")


def http(url, *, method="GET", data=None, json_body=None, headers=None, timeout=20):
    """Return (status, parsed_json). Non-2xx comes back with its body parsed."""
    body = None
    request_headers = {"User-Agent": USER_AGENT, "Accept": "application/json"}
    if data is not None:
        body = urllib.parse.urlencode(data).encode()
        request_headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif json_body is not None:
        body = json.dumps(json_body).encode()
        request_headers["Content-Type"] = "application/json"
    request_headers.update(headers or {})

    request = urllib.request.Request(url, data=body, method=method, headers=request_headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = read_capped(response)
            try:
                return response.status, (json.loads(raw) if raw.strip() else {})
            except ValueError:
                return response.status, {}
    except urllib.error.HTTPError as error:
        raw = read_capped(error)
        try:
            parsed = json.loads(raw)
        except ValueError:
            parsed = {"error_description": raw[:500]}
        # Carried alongside the body so throttled callers can honour it.
        retry_after = error.headers.get("Retry-After") if error.headers else None
        if retry_after and isinstance(parsed, dict):
            parsed["retryAfter"] = retry_after
        return error.code, parsed
    except urllib.error.URLError as error:
        return 0, {"error": "network", "error_description": str(error.reason)}
    except TimeoutError:
        return 0, {"error": "network", "error_description": "Request timed out"}


def authority_base(authority):
    return f"https://login.microsoftonline.com/{authority or DEFAULT_AUTHORITY}"


# --------------------------------------------------------------------------
# token handling
# --------------------------------------------------------------------------


def store_tokens(alias, account, token_response):
    account = dict(account)
    account["refresh_token"] = token_response.get("refresh_token", account.get("refresh_token", ""))
    account["access_token"] = token_response.get("access_token", "")
    account["expires_at"] = time.time() + int(token_response.get("expires_in", 3600)) - 120
    write_json(state_path(alias), account)
    return account


def access_token(alias, account):
    """Return a valid access token, refreshing when the cached one is stale."""
    if account.get("access_token") and time.time() < float(account.get("expires_at", 0)):
        return account["access_token"], account

    refresh_token = account.get("refresh_token")
    if not refresh_token:
        raise AccountError("auth_required", "Not signed in")

    status, payload = http(
        authority_base(account.get("authority")) + "/oauth2/v2.0/token",
        method="POST",
        data={
            "client_id": account.get("client_id", DEFAULT_CLIENT_ID),
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "scope": scopes_for(account.get("write")),
        },
    )
    if status != 200:
        code = payload.get("error", "refresh_failed")
        # invalid_grant means the refresh token is dead for good (revoked,
        # password change, conditional-access policy) - only a new sign-in fixes
        # it, so say so rather than leaving the widget retrying forever.
        kind = "auth_required" if code in ("invalid_grant", "interaction_required") else "refresh_failed"
        raise AccountError(kind, payload.get("error_description", code).split("\r")[0])

    account = store_tokens(alias, account, payload)
    return account["access_token"], account


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------


def cmd_login_start(args):
    client_id = args.client_id or DEFAULT_CLIENT_ID
    authority = args.authority or DEFAULT_AUTHORITY
    status, payload = http(
        authority_base(authority) + "/oauth2/v2.0/devicecode",
        method="POST",
        data={"client_id": client_id, "scope": scopes_for(args.write)},
    )
    if status != 200 or "device_code" not in payload:
        fail(
            "devicecode_failed",
            payload.get("error_description", "Could not start sign-in").split("\r")[0],
        )

    write_json(
        state_path(args.account, "pending"),
        {
            "device_code": payload["device_code"],
            "client_id": client_id,
            "authority": authority,
            "write": bool(args.write),
            "interval": int(payload.get("interval", 5)),
            "expires_at": time.time() + int(payload.get("expires_in", 900)),
        },
    )
    out(
        {
            "ok": True,
            "status": "pending",
            "userCode": payload.get("user_code", ""),
            "verificationUri": payload.get("verification_uri", "https://microsoft.com/devicelogin"),
            "interval": int(payload.get("interval", 5)),
            "expiresIn": int(payload.get("expires_in", 900)),
        }
    )


def cmd_login_poll(args):
    pending_path = state_path(args.account, "pending")
    pending = read_json(pending_path)
    if not pending:
        fail("no_pending_login", "No sign-in in progress")
    if time.time() > pending.get("expires_at", 0):
        os.unlink(pending_path)
        fail("expired", "The sign-in code expired, start again")

    status, payload = http(
        authority_base(pending["authority"]) + "/oauth2/v2.0/token",
        method="POST",
        data={
            "client_id": pending["client_id"],
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": pending["device_code"],
        },
    )

    if status != 200:
        error = payload.get("error", "")
        if error in ("authorization_pending", "slow_down"):
            out({"ok": True, "status": "pending", "slowDown": error == "slow_down"})
            return
        os.unlink(pending_path)
        if error == "authorization_declined":
            fail("declined", "Sign-in was declined")
        if error == "expired_token":
            fail("expired", "The sign-in code expired, start again")
        fail("login_failed", payload.get("error_description", error).split("\r")[0])

    account = store_tokens(
        args.account,
        {
            "alias": args.account,
            "client_id": pending["client_id"],
            "authority": pending["authority"],
            "write": bool(pending.get("write")),
        },
        payload,
    )
    os.unlink(pending_path)

    # Record who signed in, so the panel can show the mailbox address and the
    # user can tell instances apart without opening Outlook.
    status, me = http(
        GRAPH + "/me?$select=displayName,userPrincipalName,mail",
        headers={"Authorization": "Bearer " + account["access_token"]},
    )
    if status == 200:
        account["username"] = me.get("mail") or me.get("userPrincipalName") or ""
        account["displayName"] = me.get("displayName") or ""
        write_json(state_path(args.account), account)

    out(
        {
            "ok": True,
            "status": "signed-in",
            "write": bool(account.get("write")),
            "username": account.get("username", ""),
            "displayName": account.get("displayName", ""),
        }
    )


def graph_get_url(token, url, extra_headers=None):
    """GET one Graph URL, retrying while it asks us to slow down.

    Several mailboxes polling on the same timer is the shape Graph throttles,
    so a 429 is expected rather than exceptional; honour Retry-After instead of
    surfacing an error the user can do nothing about.
    """
    headers = {"Authorization": "Bearer " + token}
    headers.update(extra_headers or {})

    for attempt in range(3):
        status, payload = http(url, headers=headers)
        if status != 429 or attempt == 2:
            return status, payload
        delay = payload.get("retryAfter") if isinstance(payload, dict) else None
        try:
            delay = float(delay)
        except (TypeError, ValueError):
            delay = 2.0 * (attempt + 1)
        time.sleep(max(0.5, min(delay, 10.0)))
    return status, payload


def graph_get(token, path, params, extra_headers=None):
    """GET one page from a Graph collection or resource."""
    url = GRAPH + path + "?" + urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
    return graph_get_url(token, url, extra_headers)


# Graph answers a collection with as many items as were asked for and an
# @odata.nextLink when more remain. A busy week holds far more meetings than
# one page, and stopping at the first page drops the rest of the week without
# saying so - which looks exactly like a quiet afternoon.
MAX_PAGES = 10


def graph_collect(token, path, params, extra_headers=None, cap=500):
    """Every item in a Graph collection, following nextLink.

    Returns (status, items, payload, complete). `payload` is the last response,
    so a caller can still read the error out of it. `complete` is false when
    Graph still had more to give and the caps stopped the walk - a truncated
    list has to be able to say so rather than pass for the whole thing.

    A page that fails ends the walk: whatever arrived before it is worth
    drawing, and the status says the rest is missing.
    """
    status, payload = graph_get(token, path, params, extra_headers)
    items = []
    pages = 0
    complete = True
    while status == 200:
        items.extend(payload.get("value", []))
        next_link = payload.get("@odata.nextLink")
        pages += 1
        if not next_link:
            break
        if len(items) >= cap or pages >= MAX_PAGES:
            complete = False
            break
        status, payload = graph_get_url(token, next_link, extra_headers)
    return status, items[:cap], payload, complete and len(items) <= cap


def graph_error(payload, fallback):
    if not isinstance(payload, dict):
        return fallback
    error = payload.get("error")
    if isinstance(error, dict):
        return error.get("message") or error.get("code") or fallback
    return payload.get("error_description") or fallback


# Graph will only sort a filtered message query when the sorted field is
# itself the first thing filtered on. A predicate reaching back to the epoch
# restricts nothing and satisfies that rule, which is what makes "newest N
# focused" a query at all - filtering on the classification alone is refused
# as InefficientFilter, and dropping the sort returns the oldest mail there is.
ORDERABLE_PREFIX = "receivedDateTime ge 1970-01-01T00:00:00Z and "

# The panel's filters, and the query behind each. The label names the view a
# failure would leave short, so a warning can say which one rather than only
# that something went wrong.
MAIL_QUERIES = (
    ("all mail", False, False),
    ("unread", True, False),
    ("focused", False, True),
    ("focused unread", True, True),
)


def fetch_messages(token, top, timezone_name, unread_only=False, focused_only=False):
    """The newest inbox messages, or the newest matching the given filters.

    Sorting is more than some mailboxes will do in one query (Exchange answers
    with a complexity error), so fall back to a plainer form rather than
    showing the user an error we can avoid.
    """
    select = ("id,subject,from,receivedDateTime,bodyPreview,webLink,importance,"
              "hasAttachments,isRead,inferenceClassification")
    prefer = {"Prefer": f'outlook.timezone="{timezone_name}"'}
    base = {"$top": str(top), "$select": select}
    clauses = []
    if unread_only:
        clauses.append("isRead eq false")
    if focused_only:
        clauses.append("inferenceClassification eq 'focused'")
    predicate = " and ".join(clauses)

    attempts = []
    if predicate:
        # Sorted form first, spelled the way Graph will accept it.
        attempts.append(dict(base, **{"$filter": ORDERABLE_PREFIX + predicate,
                                      "$orderby": "receivedDateTime desc"}))
        attempts.append(dict(base, **{"$filter": predicate, "$orderby": "receivedDateTime desc"}))
        attempts.append(dict(base, **{"$filter": predicate}))
    else:
        attempts.append(dict(base, **{"$orderby": "receivedDateTime desc"}))
        attempts.append(base)

    status, payload = 0, {}
    for params in attempts:
        status, payload = graph_get(token, "/me/mailFolders/inbox/messages", params, prefer)
        if status == 200:
            return status, payload
        # Only a rejected query is worth retrying in a simpler form; auth and
        # network failures would just repeat.
        if status in (401, 403, 0) or status >= 500:
            break
    return status, payload


def message_row(message):
    sender = (message.get("from") or {}).get("emailAddress") or {}
    return {
        "id": message.get("id", ""),
        "subject": (message.get("subject") or "(no subject)").strip(),
        "from": sender.get("name") or sender.get("address") or "",
        "fromAddress": sender.get("address") or "",
        "received": message.get("receivedDateTime", ""),
        "preview": (message.get("bodyPreview") or "").strip()[:200],
        "webLink": message.get("webLink", ""),
        "important": message.get("importance") == "high",
        "hasAttachments": bool(message.get("hasAttachments")),
        "read": bool(message.get("isRead")),
        # Outlook's Focused Inbox split. Graph will filter on this or sort by
        # date, but not both - asking for both is a 400, and dropping the sort
        # returns the oldest mail first - so the split is applied in the panel
        # over what was fetched rather than server-side.
        "focused": message.get("inferenceClassification", "focused") != "other",
    }


# Teams (and the odd Skype) meeting. onlineMeeting.joinUrl is the one that
# actually joins; onlineMeetingUrl is the older field and is still what some
# invitations carry, so fall back to it. An event can be flagged as an online
# meeting and carry no link at all, in which case there is nothing to join.
def join_url(event):
    meeting = event.get("onlineMeeting") or {}
    return (meeting.get("joinUrl") or event.get("onlineMeetingUrl") or "").strip()


def online_provider(event):
    provider = (event.get("onlineMeetingProvider") or "").strip()
    if provider in ("", "unknown"):
        return "teams" if event.get("isOnlineMeeting") else ""
    if provider.startswith("teamsFor"):
        return "teams"
    if provider.startswith("skypeFor"):
        return "skype"
    return provider


def fetch_account(alias, args, timezone_name):
    """One mailbox's unread mail and calendar. Raises AccountError on failure."""
    account = read_json(state_path(alias))
    if not account:
        raise AccountError("auth_required", "Not signed in")

    token, account = access_token(alias, account)
    if not account.get("username"):
        status, me = http(
            GRAPH + "/me?$select=displayName,userPrincipalName,mail",
            headers={"Authorization": "Bearer " + token},
        )
        if status == 200:
            account["username"] = me.get("mail") or me.get("userPrincipalName") or ""
            account["displayName"] = me.get("displayName") or ""
            write_json(state_path(alias), account)

    result = {
        "ok": True,
        "alias": alias,
        "username": account.get("username", ""),
        "displayName": account.get("displayName", ""),
        "write": bool(account.get("write")),
        "mail": [],
        "unreadCount": 0,
        # Whether unreadCount is the inbox's own number or a floor taken from
        # the rows that did arrive.
        "unreadKnown": True,
        "events": [],
        "warnings": [],
    }

    # ---- inbox counts ----------------------------------------------------
    # One cheap call for the badge number: with the message list no longer
    # filtered to unread, its length says nothing about how many are waiting.
    status, payload = graph_get(token, "/me/mailFolders/inbox", {"$select": "unreadItemCount,totalItemCount"})
    count_known = status == 200
    if count_known:
        result["unreadCount"] = int(payload.get("unreadItemCount", 0) or 0)
    else:
        count_error = graph_error(payload, "Could not read the unread count")

    # ---- mail ------------------------------------------------------------
    # One list per combination of the panel's two filters. Each query backs one
    # view, and they are not interchangeable: the newest unread need not be
    # Focused and the newest Focused need not be unread, so the both-on view is
    # not something the other three can be made to answer. One that fails
    # leaves its own view short even while the rest look full.
    top = max(1, min(args.mails, 25))
    collected = {}
    failures = []

    for label, unread_only, focused_only in MAIL_QUERIES:
        status, payload = fetch_messages(token, top, timezone_name, unread_only, focused_only)
        if status != 200:
            failures.append((label, graph_error(payload, "Could not read mail")))
            continue
        for message in payload.get("value", []):
            row = message_row(message)
            if row["id"]:
                collected[row["id"]] = row

    result["mail"] = sorted(collected.values(), key=lambda row: row["received"], reverse=True)
    if len(failures) == len(MAIL_QUERIES):
        result["warnings"].append({"scope": "mail", "message": failures[0][1]})
    elif failures:
        # Say which views are short rather than only complaining when every
        # query failed: a full-looking list beside an empty filter is exactly
        # the case nothing else would mention.
        result["warnings"].append(
            {
                "scope": "mail",
                "message": "Mail is missing from the %s view: %s"
                % (" and ".join(label for label, _ in failures), failures[0][1]),
            }
        )

    # The inbox would not say how many are unread. Whatever the unread queries
    # did return is a floor rather than a count - flagged, so the panel can say
    # "3+" instead of claiming three, and "no unread mail" is never said on the
    # strength of a request that failed.
    if not count_known:
        result["unreadCount"] = sum(1 for row in result["mail"] if not row.get("read"))
        result["unreadKnown"] = False
        result["warnings"].append({"scope": "mail", "message": count_error})

    # ---- calendar --------------------------------------------------------
    days = max(1, min(args.days, 31))
    zone = local_zone(timezone_name)
    now = datetime.now(zone)
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    start = now if args.from_now else midnight
    # Adding days to a zone-aware time moves the wall clock and lets the zone
    # work out the offset again, so this is local midnight `days` days out even
    # when the clocks changed in between.
    end = midnight + timedelta(days=days)
    status, events, payload, complete = graph_collect(
        token,
        "/me/calendarView",
        {
            "startDateTime": start.replace(microsecond=0).isoformat(),
            "endDateTime": end.replace(microsecond=0).isoformat(),
            "$orderby": "start/dateTime",
            "$top": "50",
            # iCalUId is the same string in every mailbox invited to a meeting,
            # which is what lets one meeting arriving from two accounts be
            # recognised as one meeting rather than as two similar ones.
            # onlineMeetingUrl is the older place a join link lives; without it
            # in the select, join_url() has nothing to fall back to.
            "$select": "id,iCalUId,subject,start,end,location,isAllDay,webLink,organizer,isCancelled,showAs,"
            "isOnlineMeeting,onlineMeetingProvider,onlineMeeting,onlineMeetingUrl",
        },
        {"Prefer": f'outlook.timezone="{timezone_name}"'},
    )
    for event in events:
        if event.get("isCancelled"):
            continue
        organizer = ((event.get("organizer") or {}).get("emailAddress") or {}).get("name", "")
        result["events"].append(
            {
                "id": event.get("id", ""),
                "uid": (event.get("iCalUId") or "").strip(),
                "subject": (event.get("subject") or "(no subject)").strip(),
                "start": (event.get("start") or {}).get("dateTime", ""),
                "end": (event.get("end") or {}).get("dateTime", ""),
                "isAllDay": bool(event.get("isAllDay")),
                "location": ((event.get("location") or {}).get("displayName") or "").strip(),
                "organizer": organizer,
                "webLink": event.get("webLink", ""),
                "free": event.get("showAs") == "free",
                "joinUrl": join_url(event),
                "onlineProvider": online_provider(event),
            }
        )
    # A page that failed part-way through still leaves the earlier days drawn,
    # so say the rest is missing rather than either hiding it or throwing away
    # what did arrive.
    if status != 200:
        detail = graph_error(payload, "Could not read the calendar")
        result["warnings"].append(
            {
                "scope": "calendar",
                "message": ("Part of the calendar is missing: " + detail) if result["events"] else detail,
            }
        )
    elif not complete:
        # More meetings than this window can carry. Say so: a grid that quietly
        # stops half way through a week is worse than one that admits it.
        result["warnings"].append(
            {"scope": "calendar", "message": "Too many meetings to show them all - shorten the range"}
        )

    return result


def cmd_fetch(args):
    aliases = args.account or []
    timezone_name = local_timezone()
    snapshot = {
        "ok": True,
        "fetchedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "timeZone": timezone_name,
        "accounts": [],
    }

    if args.demo:
        snapshot["accounts"] = [demo_account(alias, index, args) for index, alias in enumerate(aliases or ["demo"])]
        out(snapshot)
        return

    # Mailboxes are fetched at the same time rather than one after another.
    # Each needs several round trips, and run in sequence a few mailboxes add
    # up to ten seconds of spinner; they are independent, and separate
    # mailboxes are throttled separately. Concurrency stays small, and a 429
    # is still honoured per request.
    def collect(alias):
        try:
            return fetch_account(alias, args, timezone_name)
        except AccountError as error:
            return {"ok": False, "alias": alias, "error": {"code": error.code, "message": error.message}}

    if len(aliases) > 1:
        import concurrent.futures

        with concurrent.futures.ThreadPoolExecutor(max_workers=min(4, len(aliases))) as pool:
            snapshot["accounts"] = list(pool.map(collect, aliases))
    else:
        snapshot["accounts"] = [collect(alias) for alias in aliases]

    out(snapshot)


# Synthetic mailboxes, so the layout can be built and shown without anyone
# signing in — and so the screenshots in the README are not somebody's inbox.
# Everything here is invented: no real names, addresses, companies or subjects.
#
# Keyed by alias with a generic fallback, so `--demo --account work --account
# personal` gives each mailbox content that suits it.

# (sender, subject, preview, read, focused)
DEMO_MAIL = {
    "work": [
        ("Priya Raman", "Re: sprint 24 scope",
         "Happy with dropping the export work to next sprint if you are.", False, True),
        ("Build service", "main #482 passed",
         "12 tests added, 0 failing. Deployed to staging.", False, True),
        ("Team digest", "What shipped in August",
         "Six releases, the new onboarding flow, and a look at what is next.", True, False),
        ("Dana Okafor", "Contract renewal — needs a signature",
         "The renewal is ready. Could you look before Friday?", False, True),
        ("Accounts", "Invoice INV-2026-0418",
         "Attached for the July retainer. Payable within 30 days.", True, True),
        ("Workspace updates", "Storage is 82% full",
         "You may want to clear out old shared drives.", True, False),
        ("Tomás Lindqvist", "Notes from the design review",
         "Wrote up the three options we talked through, with a recommendation.", False, True),
        ("Recruitment", "Two candidates for Thursday",
         "CVs attached. Both are free for an afternoon slot.", True, True),
        ("Security bulletin", "Password rotation due",
         "Your shared credentials expire in seven days.", True, False),
        ("Ana Beltrán", "Can we move the retro?",
         "Something has come up on Friday morning. Would Thursday work?", False, True),
    ],
    "personal": [
        ("Bookshop", "Your order has shipped",
         "Two items are on their way and should arrive Thursday.", False, True),
        ("The Weekly Read", "Ten longreads for the weekend",
         "This week: deep sea cables, a very old bakery, and the physics of skipping stones.",
         True, False),
        ("Energy provider", "Your August statement",
         "Your usage was 8% lower than the same month last year.", False, True),
        ("Camera club", "Prints are ready to collect",
         "The framed set from the spring exhibition is ready whenever you are.", True, False),
        ("Cycling club", "Sunday route changed",
         "Roadworks on the usual climb, so we are going the long way round.", True, False),
        ("Swim school", "Term 3 starts on the 2nd",
         "Lessons move to 17:00. Let us know if that no longer suits.", False, True),
        ("Library", "Two books are due back",
         "Renew online if you need another three weeks.", True, False),
        ("Holiday let", "Your booking is confirmed",
         "Four nights, arriving Friday. Keys are in the box by the door.", True, True),
        ("Garage", "Service reminder",
         "The annual service is due next month. Reply to book a slot.", False, False),
        ("Allotment society", "Water is back on",
         "The standpipes are running again after the repairs.", True, False),
    ],
    "family": [
        ("School office", "Parents' evening — pick a slot",
         "Booking is open until Friday. Slots are twenty minutes.", False, True),
        ("Swim school", "Term 3 timetable",
         "Lessons move to 17:00 from the first week of September.", False, True),
        ("Holiday let", "Booking confirmed",
         "Four nights, arriving Friday. Keys are in the box by the door.", True, True),
        ("Neighbourhood group", "Street party on the 12th",
         "Bring a chair. There is a sign-up sheet for cake.", True, False),
    ],
}

# (subject, location, day offset, "HH:MM", minutes, online, free)
DEMO_EVENTS = {
    "work": [
        ("Travel to the office", "", 0, "08:15", 45, False, False),
        ("Sprint planning", "Microsoft Teams Meeting", 0, "09:00", 60, True, False),
        ("Design review", "Room 2.4", 0, "11:00", 45, False, False),
        ("Lunch", "", 0, "12:30", 30, False, True),
        ("Client call", "Microsoft Teams Meeting", 0, "14:00", 30, True, False),
        ("Sprint retro", "Microsoft Teams Meeting", 1, "10:00", 45, True, False),
        ("Afternoon off", "", 1, "13:00", 300, False, True),
        ("Quarterly review", "Room 1.1", 2, "10:30", 90, False, False),
        ("Lunch", "", 2, "12:30", 30, False, True),
    ],
    "personal": [
        ("Swimming lesson — Robin", "Community pool", 0, "17:00", 45, False, False),
        ("Football practice — Sam", "Sports park", 0, "18:30", 90, False, False),
        ("Dentist", "High street", 1, "08:30", 30, False, False),
        ("Pick up the groceries", "", 1, "17:30", 30, False, False),
        ("Parents' evening", "School hall", 2, "19:00", 60, False, False),
    ],
    "family": [
        ("Swimming lesson — Robin", "Community pool", 0, "17:00", 45, False, False),
        ("Weekend away", "", 2, "", 0, False, False),
    ],
}

DEMO_FALLBACK_MAIL = [
    ("Example sender", "An example message",
     "Demo content, for building the layout without a live mailbox.", False, True),
]
DEMO_FALLBACK_EVENTS = [("Example meeting", "", 0, "10:00", 60, False, False)]


def demo_account(alias, index, args):
    """One synthetic mailbox.

    A mailbox called "broken" fails on purpose, so the per-account error state
    can be looked at without breaking a real sign-in to see it.
    """
    if alias == "broken":
        return {"ok": False, "alias": alias, "error": {"code": "auth_required", "message": "Not signed in"}}

    now = datetime.now().astimezone()
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    letters = DEMO_MAIL.get(alias, DEMO_FALLBACK_MAIL)
    meetings = DEMO_EVENTS.get(alias, DEMO_FALLBACK_EVENTS)

    mail = []
    for slot in range(max(1, min(args.mails, 25))):
        who, subject, preview, read, focused = letters[slot % len(letters)]
        received = now - timedelta(minutes=23 * (slot + 1) + 11 * index)
        mail.append(
            {
                "id": "demo-%s-%d" % (alias, slot),
                "subject": subject,
                "from": who,
                "fromAddress": who.lower().replace(" ", ".").replace("'", "") + "@example.com",
                "received": received.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
                "preview": preview,
                "webLink": "https://outlook.office.com/mail/",
                "important": slot == 0 and index == 0,
                "hasAttachments": "Invoice" in subject or "statement" in subject,
                "read": read,
                "focused": focused,
            }
        )

    events = []
    for slot, (subject, where, day_offset, clock, minutes, online, free) in enumerate(meetings):
        day = midnight + timedelta(days=day_offset)
        all_day = clock == ""
        if all_day:
            start, end = day, day + timedelta(days=1)
        else:
            hour, minute = (int(part) for part in clock.split(":"))
            start = day + timedelta(hours=hour, minutes=minute)
            end = start + timedelta(minutes=minutes)
        events.append(
            {
                "id": "demo-event-%s-%d" % (alias, slot),
                "uid": "demo-uid-%s-%d" % (alias, slot),
                "subject": subject,
                "start": start.replace(tzinfo=None).isoformat(),
                "end": end.replace(tzinfo=None).isoformat(),
                "isAllDay": all_day,
                "location": where,
                "organizer": "Example organiser",
                "webLink": "https://outlook.office.com/calendar/",
                "free": free,
                "joinUrl": "https://teams.microsoft.com/l/meetup-join/demo-%s-%d" % (alias, slot) if online else "",
                "onlineProvider": "teams" if online else "",
            }
        )

    unread = sum(1 for row in mail if not row["read"])
    return {
        "ok": True,
        "alias": alias,
        "username": "%s@example.com" % alias,
        "displayName": alias.capitalize(),
        "write": False,
        "mail": mail,
        "unreadCount": unread,
        "unreadKnown": True,
        "events": events,
        "warnings": [],
    }


def demo_message(alias, message_id):
    """The body behind a demo row, so the reading pane works in demo mode too.

    Without this, opening a synthetic message asks Graph about an id it has
    never seen and the pane shows an auth error - which is a poor way to find
    out that demo mode stops at the list.
    """
    letters = DEMO_MAIL.get(alias, DEMO_FALLBACK_MAIL)
    slot = 0
    if message_id.startswith("demo-"):
        tail = message_id.rsplit("-", 1)[-1]
        if tail.isdigit():
            slot = int(tail)
    who, subject, preview, read, _focused = letters[slot % len(letters)]
    address = who.lower().replace(" ", ".").replace("'", "") + "@example.com"
    return {
        "ok": True,
        "id": message_id,
        "subject": subject,
        "from": who,
        "fromAddress": address,
        "to": ["you@example.com"],
        "cc": [],
        "received": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "webLink": "https://outlook.office.com/mail/",
        "hasAttachments": False,
        "read": read,
        "body": preview + "\n\n"
        + "This is demo content, so the panel can be looked at and photographed "
        + "without anyone's mailbox being involved. A real message would carry "
        + "its own text here, converted to plain text by Graph before it ever "
        + "reaches this pane.\n\n"
        + "Thanks,\n" + who,
        "truncated": False,
    }


def cmd_palette(_args):
    """The active theme's named colours, so accounts can be tinted in hues that
    belong to whatever theme is running rather than hardcoded hex."""
    path = os.path.join(
        os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
        "omarchy",
        "current",
        "theme",
        "colors.toml",
    )
    names = (
        "red", "orange", "yellow", "green", "cyan", "blue", "magenta", "brown",
        "bright_red", "bright_orange", "bright_yellow", "bright_green",
        "bright_cyan", "bright_blue", "bright_magenta",
        "accent", "foreground", "muted",
    )
    try:
        import tomllib

        with open(path, "rb") as handle:
            parsed = tomllib.load(handle)
    except (OSError, ValueError, ImportError) as error:
        out({"ok": False, "error": {"code": "no_palette", "message": str(error)}, "colors": {}})
        return

    colors = {}
    for name in names:
        value = parsed.get(name)
        if isinstance(value, str) and value.startswith("#"):
            colors[name] = value
    out({"ok": True, "mode": parsed.get("mode", "dark"), "colors": colors})


def tidy_body(text):
    """Make Graph's HTML-to-text output readable in a small pane.

    It renders links as `[label]<https://very-long-safelink...>`, which buries
    the words in tracking URLs. The label is what a preview wants; the full
    thing is one Open click away.
    """
    text = text.replace("\r\n", "\n")
    text = re.sub(r"\[([^\]\n]{1,160})\]\s*<https?://[^>\n]+>", r"\1", text)
    text = re.sub(r"<(https?://[^>\s]{0,200})>", r"\1", text)
    text = re.sub(r"[ \t]+\n", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def recipients(values):
    people = []
    for entry in values or []:
        address = (entry or {}).get("emailAddress") or {}
        people.append({"name": address.get("name", ""), "address": address.get("address", "")})
    return people


def cmd_message(args):
    """One message with its body, fetched only when the user asks to read it.

    Bodies are far too big to carry in the list fetch, and Graph will convert
    HTML mail to plain text for us given the right Prefer header, which is
    exactly what a small preview pane wants.
    """
    if getattr(args, "demo", False):
        out(demo_message(args.account, args.id))
        return

    account = read_json(state_path(args.account))
    if not account:
        fail("auth_required", "Not signed in")

    try:
        token, account = access_token(args.account, account)
    except AccountError as error:
        fail(error.code, error.message)

    timezone_name = local_timezone()
    status, payload = graph_get(
        token,
        "/me/messages/" + urllib.parse.quote(args.id, safe=""),
        {"$select": "subject,from,toRecipients,ccRecipients,receivedDateTime,body,webLink,hasAttachments,isRead"},
        {"Prefer": 'outlook.body-content-type="text", outlook.timezone="%s"' % timezone_name},
    )
    if status != 200:
        fail("message_failed", graph_error(payload, "Could not open this message"))

    sender = (payload.get("from") or {}).get("emailAddress") or {}
    body = tidy_body((payload.get("body") or {}).get("content") or "")
    out(
        {
            "ok": True,
            "id": payload.get("id", args.id),
            "subject": (payload.get("subject") or "(no subject)").strip(),
            "from": sender.get("name") or sender.get("address") or "",
            "fromAddress": sender.get("address") or "",
            "to": recipients(payload.get("toRecipients")),
            "cc": recipients(payload.get("ccRecipients")),
            "received": payload.get("receivedDateTime", ""),
            "webLink": payload.get("webLink", ""),
            "hasAttachments": bool(payload.get("hasAttachments")),
            # Capped: a preview pane cannot show a novel, and the Open button
            # is one click away for the whole thing.
            "body": body[:8000],
            "truncated": len(body) > 8000,
        }
    )


def writable_token(alias):
    """A token that may change mail, or a clear reason why not."""
    account = read_json(state_path(alias))
    if not account:
        fail("auth_required", "Not signed in")
    if not account.get("write"):
        fail("write_required", "This mailbox is signed in for reading only")
    try:
        return access_token(alias, account)[0]
    except AccountError as error:
        fail(error.code, error.message)


def cmd_mark(args):
    """Mark one message read or unread."""
    token = writable_token(args.account)
    status, payload = http(
        GRAPH + "/me/messages/" + urllib.parse.quote(args.id, safe=""),
        method="PATCH",
        json_body={"isRead": args.read},
        headers={"Authorization": "Bearer " + token},
    )
    if status not in (200, 204):
        fail("mark_failed", graph_error(payload, "Could not change this message"))
    out({"ok": True, "id": args.id, "read": args.read})


def cmd_delete(args):
    """Move one message to Deleted Items.

    Graph's DELETE on a message is a move to the deleted-items folder rather
    than an erase, which is what makes a one-click button on a bar widget
    reasonable: it is undoable from Outlook.
    """
    token = writable_token(args.account)
    status, payload = http(
        GRAPH + "/me/messages/" + urllib.parse.quote(args.id, safe=""),
        method="DELETE",
        headers={"Authorization": "Bearer " + token},
    )
    if status not in (200, 204):
        fail("delete_failed", graph_error(payload, "Could not delete this message"))
    out({"ok": True, "id": args.id, "deleted": True})


def cmd_list(_args):
    accounts = []
    try:
        names = sorted(os.listdir(STATE_DIR))
    except OSError:
        names = []
    for name in names:
        if not name.endswith(".json") or name.endswith(".pending.json"):
            continue
        data = read_json(os.path.join(STATE_DIR, name), {})
        accounts.append(
            {
                "alias": data.get("alias", name[:-5]),
                "username": data.get("username", ""),
                "displayName": data.get("displayName", ""),
                "clientId": data.get("client_id", ""),
                "authority": data.get("authority", ""),
            }
        )
    out({"ok": True, "accounts": accounts})


def cmd_remove(args):
    removed = False
    for kind in ("account", "pending"):
        path = state_path(args.account, kind)
        if os.path.exists(path):
            os.unlink(path)
            removed = True
    out({"ok": True, "removed": removed})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    def with_account(name, help_text):
        item = sub.add_parser(name, help=help_text)
        item.add_argument("--account", required=True, help="account alias, e.g. work")
        return item

    start = with_account("login-start", "begin a device-code sign-in")
    start.add_argument("--client-id", default="")
    start.add_argument("--authority", default="", help="common, organizations, consumers, or a tenant id")
    start.add_argument("--write", action="store_true", help="also ask for permission to change mail")
    start.set_defaults(func=cmd_login_start)

    with_account("login-poll", "poll a pending sign-in").set_defaults(func=cmd_login_poll)

    fetch = sub.add_parser("fetch", help="fetch unread mail and calendar events")
    # Repeatable: one process serves every mailbox a widget holds.
    fetch.add_argument("--account", action="append", required=True, help="account alias; repeat for more")
    fetch.add_argument("--mails", type=int, default=5, help="unread messages kept per mailbox")
    fetch.add_argument("--days", type=int, default=3)
    fetch.add_argument("--demo", action="store_true", help="synthetic data, for building the layout")
    fetch.add_argument(
        "--from-now",
        action="store_true",
        help="start the calendar window at the current time instead of midnight",
    )
    fetch.set_defaults(func=cmd_fetch)

    message = with_account("message", "fetch one message with its body")
    message.add_argument("--id", required=True, help="message id from a fetch")
    message.add_argument("--demo", action="store_true", help="synthetic body, matching --demo fetch")
    message.set_defaults(func=cmd_message)

    mark = with_account("mark", "mark a message read or unread")
    mark.add_argument("--id", required=True)
    mark.add_argument("--read", dest="read", action="store_true")
    mark.add_argument("--unread", dest="read", action="store_false")
    mark.set_defaults(read=False, func=cmd_mark)

    delete = with_account("delete", "move a message to Deleted Items")
    delete.add_argument("--id", required=True)
    delete.set_defaults(func=cmd_delete)

    sub.add_parser("list", help="list configured accounts").set_defaults(func=cmd_list)
    sub.add_parser("palette", help="the active theme's named colours").set_defaults(func=cmd_palette)
    with_account("remove", "forget an account").set_defaults(func=cmd_remove)

    args = parser.parse_args()
    try:
        args.func(args)
    except AccountError as error:
        # Commands that work on one mailbox have no per-account layer to catch
        # this; report it the way every other failure is reported rather than
        # handing the widget a traceback on stderr.
        fail(error.code, error.message)


if __name__ == "__main__":
    main()
