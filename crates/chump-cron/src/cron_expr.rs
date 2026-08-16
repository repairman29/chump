//! 5-field cron expression parsing (M H DoM Mon DoW) plus the launchd-native
//! `StartInterval` seconds shorthand. Supports `*`, exact numbers, and
//! comma-separated lists per field — enough for the daemon schedules Chump
//! actually uses (no step syntax like `*/5`).

use anyhow::{anyhow, bail, Result};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Field {
    Any,
    List(Vec<u32>),
}

impl Field {
    fn parse(raw: &str, min: u32, max: u32, name: &str) -> Result<Self> {
        if raw == "*" {
            return Ok(Field::Any);
        }
        let mut values = Vec::new();
        for part in raw.split(',') {
            let n: u32 = part
                .trim()
                .parse()
                .map_err(|_| anyhow!("cron field '{name}': not a number: '{part}'"))?;
            if n < min || n > max {
                bail!("cron field '{name}': {n} out of range [{min},{max}]");
            }
            values.push(n);
        }
        if values.is_empty() {
            bail!("cron field '{name}': empty");
        }
        Ok(Field::List(values))
    }

    fn values(&self, min: u32, max: u32) -> Vec<u32> {
        match self {
            Field::Any => (min..=max).collect(),
            Field::List(v) => v.clone(),
        }
    }
}

/// A parsed 5-field cron schedule.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CronSchedule {
    pub minute: Field,
    pub hour: Field,
    pub dom: Field,
    pub month: Field,
    pub dow: Field,
}

impl CronSchedule {
    pub fn parse(expr: &str) -> Result<Self> {
        let fields: Vec<&str> = expr.split_whitespace().collect();
        if fields.len() != 5 {
            bail!(
                "cron expression must have exactly 5 fields (M H DoM Mon DoW), got {}: '{expr}'",
                fields.len()
            );
        }
        Ok(CronSchedule {
            minute: Field::parse(fields[0], 0, 59, "minute")?,
            hour: Field::parse(fields[1], 0, 23, "hour")?,
            dom: Field::parse(fields[2], 1, 31, "day-of-month")?,
            month: Field::parse(fields[3], 1, 12, "month")?,
            dow: Field::parse(fields[4], 0, 7, "day-of-week")?,
        })
    }

    /// launchd `StartCalendarInterval` is an array of dicts; each dict's
    /// *absent* keys act as wildcards, but present keys must each hold a
    /// single value — so a field with N explicit values needs N dict
    /// entries (cross product across all explicit fields).
    pub fn to_launchd_calendar_intervals(&self) -> Vec<Vec<(&'static str, u32)>> {
        let mut combos: Vec<Vec<(&'static str, u32)>> = vec![vec![]];
        for (key, field, min, max) in [
            ("Minute", &self.minute, 0u32, 59u32),
            ("Hour", &self.hour, 0, 23),
            ("Day", &self.dom, 1, 31),
            ("Month", &self.month, 1, 12),
            ("Weekday", &self.dow, 0, 7),
        ] {
            if let Field::List(_) = field {
                let vals = field.values(min, max);
                let mut next = Vec::with_capacity(combos.len() * vals.len());
                for combo in &combos {
                    for v in &vals {
                        let mut c = combo.clone();
                        c.push((key, *v));
                        next.push(c);
                    }
                }
                combos = next;
            }
            // Field::Any -> omit key entirely (wildcard), no combinatorial expansion.
        }
        combos
    }

    /// systemd `OnCalendar=` expression. Best-effort mapping — sufficient for
    /// the single-value-per-field schedules Chump's daemons actually use.
    pub fn to_systemd_oncalendar(&self) -> String {
        let dow = match &self.dow {
            Field::Any => None,
            Field::List(v) => Some(v.iter().map(|d| dow_name(*d)).collect::<Vec<_>>().join(",")),
        };
        let month = field_str(&self.month, "*");
        let dom = field_str(&self.dom, "*");
        let hour = field_str(&self.hour, "*");
        let minute = field_str(&self.minute, "*");

        let date_part = format!("*-{month}-{dom}");
        let time_part = format!("{hour}:{minute}:00");
        match dow {
            Some(d) => format!("{d} {date_part} {time_part}"),
            None => format!("{date_part} {time_part}"),
        }
    }
}

fn field_str(f: &Field, wildcard: &str) -> String {
    match f {
        Field::Any => wildcard.to_string(),
        Field::List(v) => v
            .iter()
            .map(|n| n.to_string())
            .collect::<Vec<_>>()
            .join(","),
    }
}

fn dow_name(d: u32) -> &'static str {
    match d % 7 {
        0 => "Sun",
        1 => "Mon",
        2 => "Tue",
        3 => "Wed",
        4 => "Thu",
        5 => "Fri",
        6 => "Sat",
        _ => unreachable!(),
    }
}

/// Parse `--interval Ns` shorthand (seconds only, e.g. "300s" or "300").
pub fn parse_interval_seconds(raw: &str) -> Result<u64> {
    let trimmed = raw.strip_suffix('s').unwrap_or(raw);
    trimmed
        .parse::<u64>()
        .map_err(|_| anyhow!("--interval must be an integer number of seconds (got '{raw}')"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_wildcard_schedule() {
        let s = CronSchedule::parse("*/1 * * * *");
        assert!(s.is_err(), "step syntax intentionally unsupported");
    }

    #[test]
    fn parses_simple_daily_schedule() {
        let s = CronSchedule::parse("30 9 * * *").unwrap();
        assert_eq!(s.minute, Field::List(vec![30]));
        assert_eq!(s.hour, Field::List(vec![9]));
        assert_eq!(s.dom, Field::Any);
        let intervals = s.to_launchd_calendar_intervals();
        assert_eq!(intervals.len(), 1);
        assert!(intervals[0].contains(&("Minute", 30)));
        assert!(intervals[0].contains(&("Hour", 9)));
        assert_eq!(s.to_systemd_oncalendar(), "*-*-* 9:30:00");
    }

    #[test]
    fn expands_list_fields_as_cross_product() {
        let s = CronSchedule::parse("0 8,20 * * *").unwrap();
        let intervals = s.to_launchd_calendar_intervals();
        assert_eq!(intervals.len(), 2);
    }

    #[test]
    fn dow_list_maps_to_systemd_names() {
        let s = CronSchedule::parse("0 9 * * 1,3,5").unwrap();
        assert_eq!(s.to_systemd_oncalendar(), "Mon,Wed,Fri *-*-* 9:0:00");
    }

    #[test]
    fn rejects_wrong_field_count() {
        assert!(CronSchedule::parse("* * *").is_err());
    }

    #[test]
    fn rejects_out_of_range() {
        assert!(CronSchedule::parse("60 * * * *").is_err());
    }

    #[test]
    fn interval_shorthand_parses_seconds() {
        assert_eq!(parse_interval_seconds("300s").unwrap(), 300);
        assert_eq!(parse_interval_seconds("300").unwrap(), 300);
        assert!(parse_interval_seconds("abc").is_err());
    }
}
