#!/usr/bin/env bash
MAIN="/Users/jeffadkins/Projects/Chump/.chump/worktrees/decompose-main/src/main.rs"
TEMP=$(mktemp)
sed -n '1,1575p' "$MAIN" > "$TEMP"
cat << 'EOF' >> "$TEMP"
    if args.get(1).map(String::as_str) == Some("pr") ||
       args.get(1).map(String::as_str) == Some("pr-rescue") ||
       args.get(1).map(String::as_str) == Some("paramedic")
    {
        cmd::pr::run(&args).await?;
        return Ok(());
    }
EOF
sed -n '1576,$p' "$MAIN" >> "$TEMP.rest"

cat << 'EOF' > delete_pr.py
import sys

with open(sys.argv[1], 'r') as f:
    lines = f.readlines()

out = []
i = 0
while i < len(lines):
    line = lines[i]
    if ('if args.get(1).map(String::as_str) == Some("pr-rescue")' in line or
        'if args.get(1).map(String::as_str) == Some("paramedic")' in line or
        'if args.get(1).map(String::as_str) == Some("pr")' in line):
        # Find closing brace
        brace_count = 0
        started = False
        while i < len(lines):
            l = lines[i]
            brace_count += l.count('{')
            brace_count -= l.count('}')
            if '{' in l: started = True
            i += 1
            if started and brace_count == 0:
                break
    else:
        out.append(line)
        i += 1

with open(sys.argv[2], 'w') as f:
    f.writelines(out)
EOF

python3 delete_pr.py "$TEMP.rest" "$TEMP.clean"
cat "$TEMP.clean" >> "$TEMP"
mv "$TEMP" "$MAIN"
rm "$TEMP.rest" "$TEMP.clean" delete_pr.py
