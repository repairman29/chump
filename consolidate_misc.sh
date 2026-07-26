#!/usr/bin/env bash
MAIN="/Users/jeffadkins/Projects/Chump/.chump/worktrees/decompose-main/src/main.rs"
TEMP=$(mktemp)
sed -n '1,963p' "$MAIN" > "$TEMP"
cat << 'EOF' >> "$TEMP"
    // Modularised global flags and miscellaneous subcommands.
    cmd::misc::run(&args).await?;
EOF
sed -n '1140,$p' "$MAIN" >> "$TEMP.rest"

cat << 'EOF' > delete_misc.py
import sys

with open(sys.argv[1], 'r') as f:
    lines = f.readlines()

out = []
i = 0
while i < len(lines):
    line = lines[i]
    if ('args.iter().any(|a| a == "--version" || a == "-V")' in line or
        'args.iter().any(|a| a == "--build-info")' in line or
        'args.get(1).map(String::as_str) == Some("self-check-staleness")' in line or
        'args.iter().position(|a| a == "--briefing")' in line or
        'args.get(1).map(String::as_str) == Some("ambient")' in line):
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

python3 delete_misc.py "$TEMP.rest" "$TEMP.clean"
cat "$TEMP.clean" >> "$TEMP"
mv "$TEMP" "$MAIN"
rm "$TEMP.rest" "$TEMP.clean" delete_misc.py
