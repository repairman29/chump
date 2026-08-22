def age: (now - (.createdAt|fromdate))/3600;
def fails: [.statusCheckRollup[]?|select(.conclusion=="FAILURE")|.name//.context];
def running: [.statusCheckRollup[]?|select(.status=="IN_PROGRESS" or .status=="QUEUED")]|length;
def sharedgate: ["fast-checks","fast-checks-required","audit","audit-required","test","verified"];
def stale_red: (fails|length)>0 and ([fails[]|select(.|IN(sharedgate[]))]|length)==(fails|length);
def price:
  age as $age | (fails|length) as $f | running as $r | .mergeStateStatus as $ms |
  (if .isDraft then 0.10
   elif (.mergeStateStatus=="MERGEABLE" or .mergeStateStatus=="CLEAN") then 0.92
   elif ($ms=="DIRTY" and $f==0) then 0.60
   elif ($ms=="DIRTY" and stale_red) then 0.50
   elif ($ms=="DIRTY") then 0.28
   elif ($ms=="BLOCKED" and $f==0 and $r>0) then 0.85
   elif ($ms=="BLOCKED" and $f==0) then 0.80
   elif (stale_red) then 0.55
   elif ($f>=5) then 0.18
   elif ($f>0) then 0.30
   else 0.50 end) as $base |
  (if ($ms=="DIRTY" and $age>8) then ($base*0.6) else $base end);
def action:
  age as $age | (fails|length) as $f | running as $r | .mergeStateStatus as $ms |
  (if .isDraft then "un-draft"
   elif ($ms=="MERGEABLE" or $ms=="CLEAN") then "MERGE-NOW"
   elif ($ms=="DIRTY" and $f==0 and $age>8) then "REBASE (reaper imminent)"
   elif ($ms=="DIRTY" and $f==0) then "rebase"
   elif ($ms=="DIRTY" and stale_red) then "rebase+rerun(stale)"
   elif ($ms=="DIRTY" and $age>8) then "CUT? resolve-or-close"
   elif ($ms=="DIRTY") then "resolve-conflict"
   elif ($ms=="BLOCKED" and $f==0 and $r>0) then "wait-CI"
   elif ($ms=="BLOCKED" and $f==0) then "merge-candidate"
   elif (stale_red) then "rebase+rerun(stale)"
   elif ($f>=5) then "CUT? deep-red"
   else "fix-own-red" end);
