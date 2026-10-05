//! Backend detection + unit-file generation for launchd (macOS) and
//! systemd user units (Linux).

use crate::cron_expr::CronSchedule;
use crate::spec::CronSpec;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Backend {
    Launchd,
    Systemd,
}

impl Backend {
    pub fn detect() -> Backend {
        if let Ok(v) = std::env::var("CHUMP_CRON_BACKEND") {
            match v.as_str() {
                "launchd" => return Backend::Launchd,
                "systemd" => return Backend::Systemd,
                _ => {}
            }
        }
        if cfg!(target_os = "macos") {
            Backend::Launchd
        } else {
            Backend::Systemd
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Backend::Launchd => "launchd",
            Backend::Systemd => "systemd",
        }
    }
}

/// Chump-managed unit files are tagged with this sentinel comment so
/// `chump cron list` (INFRA-2046) can distinguish them from operator-owned
/// plists/units, and so uninstall never touches anything else.
pub const SENTINEL: &str = "CHUMP-MANAGED-CRON-UNIT — do not hand-edit; managed by `chump cron`";

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

/// Render the launchd plist for a spec. Guarantees either
/// `StartCalendarInterval` or `StartInterval` is present (INFRA-1929 class).
pub fn render_launchd_plist(spec: &CronSpec) -> String {
    let mut argv_xml = String::new();
    for arg in &spec.exec_argv {
        argv_xml.push_str(&format!("        <string>{}</string>\n", xml_escape(arg)));
    }

    let mut envs_xml = String::new();
    if !spec.env.is_empty() {
        envs_xml.push_str("    <key>EnvironmentVariables</key>\n    <dict>\n");
        for (k, v) in &spec.env {
            envs_xml.push_str(&format!(
                "        <key>{}</key>\n        <string>{}</string>\n",
                xml_escape(k),
                xml_escape(v)
            ));
        }
        envs_xml.push_str("    </dict>\n");
    }

    let schedule_xml = match &spec.schedule {
        Schedule::Interval(secs) => {
            format!("    <key>StartInterval</key>\n    <integer>{secs}</integer>\n")
        }
        Schedule::Cron(cron) => {
            let intervals = cron.to_launchd_calendar_intervals();
            let mut s = String::from("    <key>StartCalendarInterval</key>\n    <array>\n");
            for combo in intervals {
                s.push_str("        <dict>\n");
                for (key, val) in combo {
                    s.push_str(&format!(
                        "            <key>{key}</key>\n            <integer>{val}</integer>\n"
                    ));
                }
                s.push_str("        </dict>\n");
            }
            s.push_str("    </array>\n");
            s
        }
    };

    let workdir_xml = spec
        .working_dir
        .as_ref()
        .map(|d| {
            format!(
                "    <key>WorkingDirectory</key>\n    <string>{}</string>\n",
                xml_escape(d)
            )
        })
        .unwrap_or_default();

    let stdout_xml = spec
        .stdout_log
        .as_ref()
        .map(|p| {
            format!(
                "    <key>StandardOutPath</key>\n    <string>{}</string>\n",
                xml_escape(p)
            )
        })
        .unwrap_or_default();
    let stderr_xml = spec
        .stderr_log
        .as_ref()
        .map(|p| {
            format!(
                "    <key>StandardErrorPath</key>\n    <string>{}</string>\n",
                xml_escape(p)
            )
        })
        .unwrap_or_default();

    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- {sentinel} -->
<!-- chump-cron-description: {description} -->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{label}</string>
    <key>ProgramArguments</key>
    <array>
{argv_xml}    </array>
{workdir_xml}{envs_xml}{schedule_xml}{stdout_xml}{stderr_xml}    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
"#,
        sentinel = SENTINEL,
        description = xml_escape(spec.description.as_deref().unwrap_or("")),
        label = xml_escape(&spec.label()),
    )
}

/// Render systemd `.service` + `.timer` unit content.
pub fn render_systemd_units(spec: &CronSpec) -> (String, String) {
    let exec_start = spec
        .exec_argv
        .iter()
        .map(|a| shell_quote(a))
        .collect::<Vec<_>>()
        .join(" ");

    let mut service = String::new();
    service.push_str(&format!("# {SENTINEL}\n"));
    service.push_str("[Unit]\n");
    service.push_str(&format!(
        "Description={}\n",
        spec.description.as_deref().unwrap_or(&spec.label())
    ));
    service.push_str("\n[Service]\n");
    service.push_str("Type=oneshot\n");
    if let Some(wd) = &spec.working_dir {
        service.push_str(&format!("WorkingDirectory={wd}\n"));
    }
    for (k, v) in &spec.env {
        service.push_str(&format!("Environment=\"{k}={v}\"\n"));
    }
    service.push_str(&format!("ExecStart={exec_start}\n"));
    if let Some(p) = &spec.stdout_log {
        service.push_str(&format!("StandardOutput=append:{p}\n"));
    }
    if let Some(p) = &spec.stderr_log {
        service.push_str(&format!("StandardError=append:{p}\n"));
    }

    let mut timer = String::new();
    timer.push_str(&format!("# {SENTINEL}\n"));
    timer.push_str("[Unit]\n");
    timer.push_str(&format!(
        "Description={} (timer)\n",
        spec.description.as_deref().unwrap_or(&spec.label())
    ));
    timer.push_str("\n[Timer]\n");
    match &spec.schedule {
        Schedule::Interval(secs) => {
            timer.push_str(&format!("OnUnitActiveSec={secs}s\n"));
            timer.push_str(&format!("OnBootSec={secs}s\n"));
        }
        Schedule::Cron(cron) => {
            timer.push_str(&format!("OnCalendar={}\n", cron.to_systemd_oncalendar()));
        }
    }
    timer.push_str("Persistent=true\n");
    timer.push_str("\n[Install]\n");
    timer.push_str("WantedBy=timers.target\n");

    (service, timer)
}

fn shell_quote(s: &str) -> String {
    if s.chars()
        .all(|c| c.is_ascii_alphanumeric() || "-_./=:".contains(c))
    {
        s.to_string()
    } else {
        format!("'{}'", s.replace('\'', "'\\''"))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Schedule {
    Interval(u64),
    Cron(CronSchedule),
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::{CronSpec, Scope};

    fn sample_spec(schedule: Schedule) -> CronSpec {
        CronSpec {
            name: "test-daemon".into(),
            schedule,
            exec_argv: vec!["/bin/echo".into(), "hi there".into()],
            description: Some("a test daemon".into()),
            working_dir: Some("/tmp/work".into()),
            env: vec![("FOO".into(), "bar".into())],
            stdout_log: Some("/tmp/out.log".into()),
            stderr_log: Some("/tmp/err.log".into()),
            scope: Scope::User,
        }
    }

    #[test]
    fn launchd_plist_has_calendar_interval() {
        let spec = sample_spec(Schedule::Cron(CronSchedule::parse("0 9 * * *").unwrap()));
        let xml = render_launchd_plist(&spec);
        assert!(xml.contains("StartCalendarInterval"));
        assert!(!xml.contains("StartInterval"));
        assert!(xml.contains("com.chump.test-daemon"));
        assert!(xml.contains(SENTINEL));
        assert!(xml.contains("hi there"));
    }

    #[test]
    fn launchd_plist_has_start_interval() {
        let spec = sample_spec(Schedule::Interval(300));
        let xml = render_launchd_plist(&spec);
        assert!(xml.contains("StartInterval"));
        assert!(!xml.contains("StartCalendarInterval"));
    }

    #[test]
    fn systemd_units_render() {
        let spec = sample_spec(Schedule::Interval(60));
        let (service, timer) = render_systemd_units(&spec);
        assert!(service.contains("ExecStart=/bin/echo 'hi there'"));
        assert!(timer.contains("OnUnitActiveSec=60s"));
        assert!(service.contains(SENTINEL));
    }
}
