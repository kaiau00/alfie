"""What must never become a learned claim, enforced in code.

The distil prompt forbids secrets, addresses and medical detail, and an
audit of a real profile on 2026-09-22 found all three anyway — a phone
number, an email, a Zelle handle, a parent's street address, a flat's
address and rent, a health-fund line and a mental-health line, out of 138
claims from one WhatsApp crawl. A prompt is a request; this file is the
refusal. It runs in three places:

  * distil.parse_reply — every claim the model returns, before the digest
    is written (so nothing sensitive reaches disk from a new crawl);
  * consolidate.py — every crawled line already in the profile, so a line
    learned before this existed is removed on the next nightly pass;
  * seed-memory.py — the hand-off to Hermes's own memory (SECRET_RE and
    HEALTH_RE were born there and are imported from here now).

`reason(text)` names the first category a line falls in, or "" when it is
clean. Categories: secret, health, phone, email, address, payment, money.

Tuned for precision on the categories where the owner's own world is full
of look-alikes ("token limits", "routing traffic", "diagnostics
dashboard"), and for recall on the ones where a miss is a leak (a phone
number, a street address, a sum of money beside a name). A specific money
amount is refused outright: "pays Dani $400 for the sukkah" and "rent is
$2,300" are both things a person would not want read back into every
prompt, and the durable fact ("builds sukkahs for hire") survives without
the figure.

Python 3.9, stdlib only.
"""

import re

# Born in seed-memory.py (and still used there): a STRONG secret word joined
# to a value, account/routing numbers, card-length digit runs, token shapes
# and app-password quads.
SECRET_RE = re.compile(
    r"(?i)\b(?:pass(?:word|code|phrase)|api[-\s]?keys?|otp|"
    r"one[-\s]?time\s+codes?|verification\s+codes?|pin|cvv|ssn|social\s+security)\b"
    r"\s*(?:is|are|:|=|number|no\.?|#)\s*\S"                     # strong label + connective + value
    r"|\b(?:account|routing)\s*(?:number|no\.?|#)\b"            # account/routing NUMBER, not "routing traffic"
    r"|\b(?:\d[ -]?){13,19}\b"                                   # card / long account numbers
    r"|\b(?:sk|pk|ghp|gho|ghs|xox[baprs])[-_][A-Za-z0-9]{8,}\b"  # token shapes
    r"|\b[A-Za-z0-9]{4,}-[A-Za-z0-9]{4,}-[A-Za-z0-9]{4,}-[A-Za-z0-9]{4,}\b")  # app-password quads

# The user's health, medical and mental-health detail, plus the Israeli
# health funds (a "Clalit"/"Maccabi" line is a health-fund line). Medical-
# specific words only, so "diagnostics" and "prescriptive" survive.
HEALTH_RE = re.compile(
    r"(?i)\b(?:mychart|health\s*(?:plan|fund|insurance)|insurance\s+coverage|unitedhealthcare|"
    r"blue\s*cross|copay|deductible|medicaid|medicare|medications?|prescribed|prescriptions?|"
    r"diagnosed(?:\s+with)?|diagnosis|neurolog\w*|oncolog\w*|cardiolog\w*|psychiatr\w*|"
    r"psycholog(?:ist|ists)|therap(?:y|ist|ists|ies)|counsel(?:l)?ing|counsel(?:l)?or|"
    r"mental[-\s]health|depress(?:ion|ed|ive)|anxiety|panic\s+attacks?|adhd|ocd|ptsd|bipolar|"
    r"autis(?:m|tic)|eating\s+disorder|rehab|addiction|pregnan(?:t|cy)|fertility|ivf|miscarriage|"
    r"surgery|chemo(?:therapy)?|cancer|diabet(?:es|ic)|hospitali[sz]ed|"
    r"medical\s+(?:record|condition|appointment|leave)|"
    r"kupat\s+[ch]olim|clalit|maccabi\s+(?:health|sherutei)|meuhedet|leumit)\b"
    r"|קופת\s*חולים|כללית|מכבי\s+שירותי|מאוחדת|לאומית|טיפול\s+פסיכולוגי|פסיכיאטר|פסיכולוג")

EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")

# A phone number: 9–15 digits written with the punctuation people use, or a
# leading +. A date ("2026-09-22", 8 digits) and a year range are not one.
PHONE_RE = re.compile(r"(?<![\w-])\+?\d[\d\s().-]{7,18}\d(?![\w-])")
DATE_LIKE = re.compile(r"^\d{4}-\d{2}-\d{2}$|^\d{1,2}[./-]\d{1,2}[./-]\d{2,4}$")

# A street address: a house number, one to four words, a street type; or an
# apartment/unit; or the plain phrasing of one. Hebrew "רחוב"/"רח'" too.
_STREET = (r"st|street|ave|avenue|rd|road|blvd|boulevard|ln|lane|dr|drive|ct|court|pl|place|"
           r"way|terrace|ter|pkwy|parkway|hwy|highway|cir|circle|sq|square")
ADDRESS_RE = re.compile(
    r"(?i)\b\d{1,5}[a-z]?\s+(?:[A-Za-z][\w'.-]*\s+){1,4}(?:" + _STREET + r")\b\.?"
    r"|\b(?:apt|apartment|unit|suite|flat)\s*#?\s*\d+\w?\b"
    r"|\b(?:lives|living|lived|moved|moving|resides|staying)\s+(?:at|on)\s+\d"
    r"|\b(?:home|street|mailing|postal|billing|shipping)\s+address\b"
    r"|\baddress\s+(?:is|:)"
    r"|\b[A-Z]{2}\s+\d{5}(?:-\d{4})?\b"
    # the street first and the number after it, as Israeli and European
    # addresses are written: "Rechov Bar Ilan 12", "HaPalmach St. 5"
    r"|\b(?:st|street|rd|road|ave|avenue|blvd|boulevard|lane|ln|dr|drive|way|rechov|rehov|rehob|sderot|derech)\.?"
    r"\s+(?:[A-Za-z][\w'-]*\s+){0,3}\d{1,5}[a-z]?\b"
    r"|\b(?:rechov|rehov|sderot|derech)\s+\S"
    r"|\baddress(?:es)?\b"
    r"|\b(?:lives|living|lived|moved|moving|resides|staying)\s+(?:at|on)\s+[A-Z]"
    r"|\b(?:apartment|apt|flat|house|home)\s+(?:number|no\.?|#)\s*\d"
    r"|רחוב\s+\S|רח['׳]\s*\S|דירה\s+\d|כתובת")

# Payment rails and handles: naming the rail next to a person is how an
# account detail leaked ("Zelle: …"). Mentioning one at all is refused —
# "pays the babysitter by Zelle" is not worth the risk of the next line.
PAYMENT_RE = re.compile(
    r"(?i)\b(?:zelle|venmo|cash\s?app|paypal(?:\.me)?|iban|swift\s+code|bic\s+code|sort\s+code|"
    r"bank\s+(?:account|details|transfer\s+details)|wire\s+(?:details|instructions)|"
    r"credit\s+card|debit\s+card|paybox|bit\s+app)\b"
    r"|\$[A-Za-z][\w-]{2,}")                                  # a Cash App $cashtag

# A specific amount of money: a currency sign or code with a number, or a
# number with a currency word. "$400", "₪2,300", "400 dollars", "3k NIS".
MONEY_RE = re.compile(
    r"(?i)[$€£₪¥]\s?\d|\d[\d,.]*\s?[kKmM]?\s?[$€£₪]"
    r"|\b\d[\d,.]*\s?[km]?\s*(?:dollars?|bucks|usd|nis|ils|shekels?|shek|euros?|eur|pounds?\s+sterling|gbp)\b"
    r"|\b(?:usd|nis|ils|eur|gbp)\s?\d"
    r"|\b(?:rent|salary|paid|pays|owes|owed|charges?|costs?|price[ds]?|fee)\b[^.;]{0,25}\d{2,}"
    r"|\d[\d,.]*\s*(?:ש\"ח|שקל|שקלים|₪)")


def _phone(text):
    for m in PHONE_RE.finditer(text):
        s = m.group(0).strip()
        if DATE_LIKE.match(s):
            continue
        digits = re.sub(r"\D", "", s)
        # 9+ digits, or a +country form of 8+; a year range like 2025-2026
        # has 8 and is not a number anyone dials.
        if len(digits) >= 9 or (s.startswith("+") and len(digits) >= 8):
            if re.fullmatch(r"(?:19|20)\d\d\s*[-–]\s*(?:19|20)\d\d", s):
                continue
            return True
    return False


CHECKS = (
    ("secret", SECRET_RE.search),
    ("health", HEALTH_RE.search),
    ("email", EMAIL_RE.search),
    ("phone", _phone),
    ("address", ADDRESS_RE.search),
    ("payment", PAYMENT_RE.search),
    ("money", MONEY_RE.search),
)


def reason(text):
    """The first category `text` falls in, or "" when it may be kept."""
    t = str(text or "")
    for name, check in CHECKS:
        if check(t):
            return name
    return ""


def sensitive(text):
    return bool(reason(text))
