# 1. Change version: 1.0.0+1 → 1.0.1+2 in pubspec.yaml
# 2. Commit and push
git add . && git commit -m "v1.0.1" && git push origin main
# 3. Done! GitHub builds and publishes everything automatically.


version: MAJOR.MINOR.PATCH+BUILD
         1    .0    .0    +1


The Number After + (Build Number)
Part	Rule
BUILD	Must always go up by 1 on every release. Android uses this internally. Never decrease it.


The 3 Parts Before the + (Version Name)
Part	When to Increment	Example
MAJOR (1st)	Big redesign, breaking changes, major new features	1.0.0 → 2.0.0
MINOR (2nd)	New features added, but nothing breaking	1.0.0 → 1.1.0
PATCH (3rd)	Bug fixes, small tweaks, UI polish	1.0.0 → 1.0.1
