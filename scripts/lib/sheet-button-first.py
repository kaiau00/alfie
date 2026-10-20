"""The Download sheet's button has to come before anything foldable.

Its own file rather than a heredoc inside test-site-download.sh, because a
heredoc inside a heredoc is how this check was first written and the inner
terminator closed the outer one.
"""
import re
import sys

s = open("site/index.html", encoding="utf-8").read()
start = s.index('<div class="sheet" id="get"')
sheet = s[start:s.index("\n</div>\n", s.index('class="panel"', start))]

button = sheet.find('href="/download"')
fold = sheet.find("<details")
if button < 0:
    print("      the sheet has no Download button at all")
    sys.exit(1)
if 0 <= fold < button:
    print("      the Download button is below a fold; it has to come first")
    sys.exit(1)
paragraphs = re.findall(r"<p[ >]", sheet[:button])
if len(paragraphs) > 3:
    print("      %d paragraphs before the button; three is the ceiling" % len(paragraphs))
    sys.exit(1)
print("      button first, after %d short lines" % len(paragraphs))
