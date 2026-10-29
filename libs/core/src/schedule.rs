//! When a job runs.
//!
//! Three forms:
//! - A cron expression with five fields, `minute hour day-of-month month
//!   day-of-week`, in the Mac's local time: `0 9 * * wed` is every Wednesday
//!   at 09:00. Names (`jan`, `wed`), lists (`1,15`), ranges (`mon-fri`) and
//!   steps (`*/15`) work. `@hourly`, `@daily`, `@weekly`, `@monthly` and
//!   `@yearly` are short forms.
//! - `@at 2026-11-05 09:00`: once, at that local time.
//! - `@in 20m`: once, that long from now. `resolve` turns it into `@at`
//!   when the job is saved, so the time does not move on each restart.
//!
//! Day-of-month and day-of-week follow classic cron: when both are restricted
//! (neither starts with `*`), a day matches if either one matches.

use chrono::{DateTime, Datelike, Duration, LocalResult, NaiveDate, NaiveDateTime, NaiveTime, TimeZone, Timelike};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{0}")]
pub struct ScheduleError(pub String);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Schedule {
    Cron(Cron),
    /// Once, at this local time.
    At(NaiveDateTime),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cron {
    minutes: u64,
    hours: u32,
    days: u32,
    months: u16,
    weekdays: u8,
    day_star: bool,
    weekday_star: bool,
}

const MONTHS: [&str; 12] = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
const WEEKDAYS: [&str; 7] = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
const WEEKDAY_NAMES: [&str; 7] = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const MONTH_NAMES: [&str; 12] =
    ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

/// How far `next_after` looks ahead. `0 0 29 2 *` (29 February) runs within 8 years.
const LOOKAHEAD_DAYS: i64 = 366 * 9;

impl Schedule {
    pub fn parse(text: &str) -> Result<Self, ScheduleError> {
        let text = text.trim();
        if let Some(rest) = text.strip_prefix("@at") {
            return parse_at(rest.trim()).map(Schedule::At);
        }
        if in_rest(text).is_some() {
            return Err(ScheduleError(format!("{text:?} is a time from now: @in becomes @at when the job is saved")));
        }
        let expanded = match text.to_ascii_lowercase().as_str() {
            "@yearly" | "@annually" => "0 0 1 1 *".to_string(),
            "@monthly" => "0 0 1 * *".to_string(),
            "@weekly" => "0 0 * * 0".to_string(),
            "@daily" | "@midnight" => "0 0 * * *".to_string(),
            "@hourly" => "0 * * * *".to_string(),
            other if other.starts_with('@') => {
                return Err(ScheduleError(format!(
                    "unknown schedule {text:?}: use five cron fields, @hourly, @daily, @weekly, @monthly, @yearly, @at YYYY-MM-DD HH:MM or @in 20m"
                )));
            }
            _ => text.to_string(),
        };
        Cron::parse(&expanded).map(Schedule::Cron)
    }

    /// The first run time strictly after `after`, or None (an `@at` time
    /// that has passed, or a date that never comes, like 31 February).
    pub fn next_after<Tz: TimeZone>(&self, after: &DateTime<Tz>) -> Option<DateTime<Tz>> {
        match self {
            Schedule::Cron(cron) => cron.next_after(after),
            Schedule::At(at) => earliest(&after.timezone(), at).filter(|t| t > after),
        }
    }

    pub fn is_once(&self) -> bool {
        matches!(self, Schedule::At(_))
    }

    /// Plain English for the menu bar app and for agents to confirm what they
    /// set: "At 09:00 on Wednesday". Falls back to the expression.
    pub fn describe(&self) -> String {
        match self {
            Schedule::At(at) => {
                let time = if at.second() == 0 { at.format("%H:%M") } else { at.format("%H:%M:%S") };
                format!("Once, on {} at {time}", at.format("%a %-d %b %Y"))
            }
            Schedule::Cron(cron) => cron.describe(),
        }
    }
}

fn parse_at(text: &str) -> Result<NaiveDateTime, ScheduleError> {
    let text = text.replace('T', " ");
    for format in ["%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M:%S"] {
        if let Ok(t) = NaiveDateTime::parse_from_str(&text, format) {
            return Ok(t);
        }
    }
    Err(ScheduleError(format!("@at needs a local time like \"@at 2026-11-05 09:00\", not {text:?}")))
}

/// `@in 20m` becomes `@at` that long after `now`, to the second. Every other
/// schedule comes back as it is.
pub fn resolve<Tz: TimeZone>(text: &str, now: &DateTime<Tz>) -> Result<String, ScheduleError> {
    let Some(rest) = in_rest(text.trim()) else { return Ok(text.to_string()) };
    let at = (now.clone() + parse_in(rest)?).naive_local();
    Ok(format!("@at {}", at.format("%Y-%m-%d %H:%M:%S")))
}

/// The text after `@in`, in any case.
fn in_rest(text: &str) -> Option<&str> {
    text.get(..3).filter(|p| p.eq_ignore_ascii_case("@in")).map(|_| &text[3..])
}

/// `20m`, `1h30m`, `1h 30m`, `45s`, `2 days`: more than zero, at most
/// `LOOKAHEAD_DAYS`.
fn parse_in(text: &str) -> Result<Duration, ScheduleError> {
    let bad = || ScheduleError(format!("@in needs a time from now like \"@in 20m\", \"@in 1h30m\" or \"@in 45s\", not {:?}", text.trim()));
    let mut rest = text.trim();
    if rest.is_empty() {
        return Err(bad());
    }
    let mut seconds: i64 = 0;
    while !rest.is_empty() {
        let digits = rest.find(|c: char| !c.is_ascii_digit()).unwrap_or(rest.len());
        let n: i64 = rest[..digits].parse().map_err(|_| bad())?;
        rest = rest[digits..].trim_start();
        let letters = rest.find(|c: char| !c.is_ascii_alphabetic()).unwrap_or(rest.len());
        let unit = match rest[..letters].to_ascii_lowercase().as_str() {
            "s" | "sec" | "secs" | "second" | "seconds" => 1,
            "m" | "min" | "mins" | "minute" | "minutes" => 60,
            "h" | "hr" | "hrs" | "hour" | "hours" => 3600,
            "d" | "day" | "days" => 86400,
            _ => return Err(bad()),
        };
        rest = rest[letters..].trim_start();
        seconds = n.checked_mul(unit).and_then(|s| seconds.checked_add(s)).ok_or_else(bad)?;
    }
    if seconds == 0 || seconds > LOOKAHEAD_DAYS * 86400 {
        return Err(bad());
    }
    Ok(Duration::seconds(seconds))
}

/// The local time as an instant. In the autumn hour that happens twice, the
/// first one; in the spring hour that does not exist, None.
fn earliest<Tz: TimeZone>(tz: &Tz, t: &NaiveDateTime) -> Option<DateTime<Tz>> {
    match tz.from_local_datetime(t) {
        LocalResult::Single(t) => Some(t),
        LocalResult::Ambiguous(first, _) => Some(first),
        LocalResult::None => None,
    }
}

impl Cron {
    pub fn parse(text: &str) -> Result<Self, ScheduleError> {
        let fields: Vec<&str> = text.split_whitespace().collect();
        if fields.len() != 5 {
            return Err(ScheduleError(format!(
                "a cron expression has 5 fields (minute hour day-of-month month day-of-week), {text:?} has {}",
                fields.len()
            )));
        }
        let minutes = field(fields[0], "minute", 0, 59, &[])?;
        let hours = field(fields[1], "hour", 0, 23, &[])?;
        let days = field(fields[2], "day-of-month", 1, 31, &[])?;
        let months = field(fields[3], "month", 1, 12, &MONTHS)?;
        // 7 is Sunday too.
        let mut weekdays = field(fields[4], "day-of-week", 0, 7, &WEEKDAYS)?;
        if weekdays & (1 << 7) != 0 {
            weekdays = (weekdays | 1) & 0x7f;
        }
        Ok(Cron {
            minutes,
            hours: hours as u32,
            days: days as u32,
            months: months as u16,
            weekdays: weekdays as u8,
            day_star: fields[2].starts_with('*'),
            weekday_star: fields[4].starts_with('*'),
        })
    }

    fn day_matches(&self, date: NaiveDate) -> bool {
        let dom = self.days & (1 << date.day()) != 0;
        let dow = self.weekdays & (1 << date.weekday().num_days_from_sunday()) != 0;
        if self.day_star || self.weekday_star { dom && dow } else { dom || dow }
    }

    pub fn next_after<Tz: TimeZone>(&self, after: &DateTime<Tz>) -> Option<DateTime<Tz>> {
        let tz = after.timezone();
        let start = after.naive_local();
        let mut t = start.with_second(0)?.with_nanosecond(0)? + Duration::minutes(1);
        let limit = start + Duration::days(LOOKAHEAD_DAYS);
        while t < limit {
            if self.months & (1 << t.month()) == 0 {
                let (y, m) = if t.month() == 12 { (t.year() + 1, 1) } else { (t.year(), t.month() + 1) };
                t = NaiveDate::from_ymd_opt(y, m, 1)?.and_time(NaiveTime::MIN);
                continue;
            }
            if !self.day_matches(t.date()) {
                t = t.date().succ_opt()?.and_time(NaiveTime::MIN);
                continue;
            }
            if self.hours & (1 << t.hour()) == 0 {
                t = t.with_minute(0)? + Duration::hours(1);
                continue;
            }
            if self.minutes & (1 << t.minute()) == 0 {
                t += Duration::minutes(1);
                continue;
            }
            if let Some(found) = earliest(&tz, &t).filter(|found| found > after) {
                return Some(found);
            }
            t += Duration::minutes(1);
        }
        None
    }

    fn describe(&self) -> String {
        let minutes = bits(self.minutes, 0, 59);
        let hours = bits(self.hours as u64, 0, 23);
        let time = match (minutes.as_slice(), hours.as_slice()) {
            ([m], [h]) => format!("At {h:02}:{m:02}"),
            ([m], hs) if hs.len() == 24 => format!("Every hour at minute {m}"),
            ([m], hs) => {
                let list: Vec<String> = hs.iter().map(|h| format!("{h:02}:{m:02}")).collect();
                format!("At {}", join_and(&list))
            }
            (ms, hs) if hs.len() == 24 && ms.len() == 60 => "Every minute".to_string(),
            (ms, hs) if hs.len() == 24 => match step_of(ms, 60) {
                Some(step) => format!("Every {step} minutes"),
                None => return self.fallback(),
            },
            _ => return self.fallback(),
        };
        let mut parts = vec![time];
        let weekdays = bits(self.weekdays as u64, 0, 6);
        let days = bits(self.days as u64, 1, 31);
        let weekday_text = || -> String {
            if weekdays == [1, 2, 3, 4, 5] {
                "on weekdays".to_string()
            } else if weekdays == [0, 6] {
                "on weekends".to_string()
            } else {
                let names: Vec<String> = weekdays.iter().map(|d| WEEKDAY_NAMES[*d as usize].to_string()).collect();
                format!("on {}", join_and(&names))
            }
        };
        let day_text = || -> String {
            let list: Vec<String> = days.iter().map(|d| d.to_string()).collect();
            format!("on day {} of the month", join_and(&list))
        };
        match (self.day_star, self.weekday_star) {
            (true, true) => {}
            (true, false) => parts.push(weekday_text()),
            (false, true) => parts.push(day_text()),
            (false, false) => parts.push(format!("{} or {}", day_text(), weekday_text())),
        }
        let months = bits(self.months as u64, 1, 12);
        if months.len() != 12 {
            let names: Vec<String> = months.iter().map(|m| MONTH_NAMES[*m as usize - 1].to_string()).collect();
            parts.push(format!("in {}", join_and(&names)));
        }
        parts.join(" ")
    }

    fn fallback(&self) -> String {
        "Custom cron schedule".to_string()
    }
}

/// The set bits between `low` and `high`, in order.
fn bits(mask: u64, low: u32, high: u32) -> Vec<u32> {
    (low..=high).filter(|i| mask & (1 << i) != 0).collect()
}

/// `[0, 15, 30, 45]` in 60 is every 15.
fn step_of(values: &[u32], size: u32) -> Option<u32> {
    let first = *values.first()?;
    if first != 0 || values.len() < 2 {
        return None;
    }
    let step = values[1];
    (step > 0 && size.is_multiple_of(step) && values.iter().enumerate().all(|(i, v)| *v == i as u32 * step)
        && values.len() as u32 == size / step)
        .then_some(step)
}

fn join_and(items: &[String]) -> String {
    match items {
        [] => String::new(),
        [one] => one.clone(),
        [rest @ .., last] => format!("{} and {last}", rest.join(", ")),
    }
}

/// One field as a bit mask: bit `i` set when value `i` matches.
fn field(text: &str, name: &str, low: u32, high: u32, names: &[&str]) -> Result<u64, ScheduleError> {
    let bad = |why: &str| ScheduleError(format!("{name} field {text:?}: {why}"));
    let mut mask = 0u64;
    for item in text.split(',') {
        let (range, step) = match item.split_once('/') {
            Some((range, step)) => {
                let step: u32 = step.parse().map_err(|_| bad("the step after / must be a number"))?;
                if step == 0 {
                    return Err(bad("the step cannot be 0"));
                }
                (range, step)
            }
            None => (item, 1),
        };
        let (from, to) = if range == "*" {
            (low, high)
        } else if let Some((a, b)) = range.split_once('-') {
            (value(a, low, high, names).ok_or_else(|| bad("bad range start"))?, value(b, low, high, names).ok_or_else(|| bad("bad range end"))?)
        } else {
            let v = value(range, low, high, names).ok_or_else(|| bad(&format!("use {low}-{high}")))?;
            // "5/10" means from 5 to the end, every 10.
            (v, if item.contains('/') { high } else { v })
        };
        if from > to {
            return Err(bad("a range must go from low to high"));
        }
        let mut v = from;
        while v <= to {
            mask |= 1 << v;
            v += step;
        }
    }
    Ok(mask)
}

fn value(text: &str, low: u32, high: u32, names: &[&str]) -> Option<u32> {
    let lower = text.to_ascii_lowercase();
    if let Some(i) = names.iter().position(|n| *n == lower) {
        // Month names start at 1, weekday names at 0.
        return Some(i as u32 + low);
    }
    let v: u32 = text.parse().ok()?;
    (low..=high).contains(&v).then_some(v)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{FixedOffset, Utc};

    fn at(s: &str) -> DateTime<Utc> {
        NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M").unwrap().and_utc()
    }

    fn next(expr: &str, from: &str) -> String {
        Schedule::parse(expr).unwrap().next_after(&at(from)).unwrap().format("%Y-%m-%d %H:%M %a").to_string()
    }

    #[test]
    fn wednesday_at_nine() {
        // 2026-10-28 is a Wednesday.
        assert_eq!(next("0 9 * * 3", "2026-10-28 08:59"), "2026-10-28 09:00 Wed");
        assert_eq!(next("0 9 * * wed", "2026-10-28 09:00"), "2026-11-04 09:00 Wed");
        assert_eq!(next("0 9 * * WED", "2026-10-26 10:00"), "2026-10-28 09:00 Wed");
    }

    #[test]
    fn steps_lists_and_ranges() {
        assert_eq!(next("*/15 * * * *", "2026-10-28 10:07"), "2026-10-28 10:15 Wed");
        assert_eq!(next("5/20 * * * *", "2026-10-28 10:26"), "2026-10-28 10:45 Wed");
        assert_eq!(next("30 8 * * mon-fri", "2026-10-30 09:00"), "2026-11-02 08:30 Mon");
        assert_eq!(next("0 0 1,15 * *", "2026-10-02 00:00"), "2026-10-15 00:00 Thu");
        assert_eq!(next("0 12 * jan *", "2026-10-28 00:00"), "2027-01-01 12:00 Fri");
    }

    #[test]
    fn sunday_is_zero_and_seven() {
        assert_eq!(next("0 10 * * 7", "2026-10-28 00:00"), "2026-11-01 10:00 Sun");
        assert_eq!(next("0 10 * * 0", "2026-10-28 00:00"), "2026-11-01 10:00 Sun");
    }

    #[test]
    fn day_of_month_or_day_of_week_when_both_are_set() {
        // Classic cron: the 1st of the month OR any Friday.
        assert_eq!(next("0 0 1 * fri", "2026-10-28 00:00"), "2026-10-30 00:00 Fri");
        assert_eq!(next("0 0 1 * fri", "2026-10-30 00:00"), "2026-11-01 00:00 Sun");
        // With a star in one field both must match.
        assert_eq!(next("0 0 */1 * fri", "2026-10-28 00:00"), "2026-10-30 00:00 Fri");
    }

    #[test]
    fn rare_dates() {
        assert_eq!(next("0 0 29 2 *", "2026-10-28 00:00"), "2028-02-29 00:00 Tue");
        assert!(Schedule::parse("0 0 31 2 *").unwrap().next_after(&at("2026-10-28 00:00")).is_none());
    }

    #[test]
    fn macros() {
        assert_eq!(next("@daily", "2026-10-28 10:00"), "2026-10-29 00:00 Thu");
        assert_eq!(next("@hourly", "2026-10-28 10:00"), "2026-10-28 11:00 Wed");
        assert_eq!(next("@weekly", "2026-10-28 10:00"), "2026-11-01 00:00 Sun");
        assert_eq!(next("@monthly", "2026-10-28 10:00"), "2026-11-01 00:00 Sun");
    }

    #[test]
    fn at_runs_once() {
        let s = Schedule::parse("@at 2026-11-05 09:00").unwrap();
        assert!(s.is_once());
        assert_eq!(s.next_after(&at("2026-10-28 00:00")).unwrap(), at("2026-11-05 09:00"));
        assert!(s.next_after(&at("2026-11-05 09:00")).is_none());
        assert_eq!(Schedule::parse("@at 2026-11-05T09:00").unwrap(), s);
    }

    #[test]
    fn at_keeps_seconds() {
        let s = Schedule::parse("@at 2026-11-05 09:00:30").unwrap();
        assert_eq!(s.next_after(&at("2026-11-05 09:00")).unwrap().format("%H:%M:%S").to_string(), "09:00:30");
        assert_eq!(s.describe(), "Once, on Thu 5 Nov 2026 at 09:00:30");
    }

    #[test]
    fn in_becomes_at_from_now() {
        let now = Utc.with_ymd_and_hms(2026, 10, 29, 14, 7, 13).unwrap();
        let r = |s: &str| resolve(s, &now).unwrap();
        assert_eq!(r("@in 20m"), "@at 2026-10-29 14:27:13");
        assert_eq!(r("@in 1h30m"), "@at 2026-10-29 15:37:13");
        assert_eq!(r("@in 1h 30m"), "@at 2026-10-29 15:37:13");
        assert_eq!(r("@in 45s"), "@at 2026-10-29 14:07:58");
        assert_eq!(r("@in 2 days"), "@at 2026-10-31 14:07:13");
        assert_eq!(r("@IN 10 Minutes"), "@at 2026-10-29 14:17:13");
        // Other schedules come back as they are.
        assert_eq!(r("0 9 * * wed"), "0 9 * * wed");
        assert_eq!(r("@at 2026-11-05 09:00"), "@at 2026-11-05 09:00");
        assert!(Schedule::parse(&r("@in 20m")).unwrap().is_once());
    }

    #[test]
    fn in_errors() {
        let now = Utc.with_ymd_and_hms(2026, 10, 29, 14, 7, 13).unwrap();
        let e = |s: &str| resolve(s, &now).unwrap_err().0;
        for bad in ["@in", "@in 0m", "@in 20", "@in m", "@in 20 parsecs", "@in -5m", "@in 99999999999999999999s", "@in 10000d"] {
            assert!(e(bad).contains("@in"), "{bad}: {}", e(bad));
        }
        // Not resolved: the daemon resolves it when the job is saved.
        assert!(Schedule::parse("@in 20m").unwrap_err().0.contains("@in"));
    }

    #[test]
    fn local_offset_is_used() {
        let tz = FixedOffset::east_opt(3600).unwrap();
        let from = tz.with_ymd_and_hms(2026, 10, 28, 8, 0, 0).unwrap();
        let found = Schedule::parse("0 9 * * *").unwrap().next_after(&from).unwrap();
        assert_eq!(found.format("%H:%M %z").to_string(), "09:00 +0100");
    }

    #[test]
    fn errors_name_the_field() {
        let e = |s: &str| Schedule::parse(s).unwrap_err().0;
        assert!(e("0 9 * *").contains("5 fields"));
        assert!(e("60 9 * * *").contains("minute"));
        assert!(e("0 24 * * *").contains("hour"));
        assert!(e("0 9 * * funday").contains("day-of-week"));
        assert!(e("*/0 * * * *").contains("step"));
        assert!(e("0 9 5-1 * *").contains("low to high"));
        assert!(e("@sometimes").contains("unknown schedule"));
        assert!(e("@at tomorrow").contains("@at"));
    }

    #[test]
    fn descriptions() {
        let d = |s: &str| Schedule::parse(s).unwrap().describe();
        assert_eq!(d("0 9 * * wed"), "At 09:00 on Wednesday");
        assert_eq!(d("30 8 * * 1-5"), "At 08:30 on weekdays");
        assert_eq!(d("0 9,17 * * *"), "At 09:00 and 17:00");
        assert_eq!(d("*/15 * * * *"), "Every 15 minutes");
        assert_eq!(d("0 * * * *"), "Every hour at minute 0");
        assert_eq!(d("0 0 1 * *"), "At 00:00 on day 1 of the month");
        assert_eq!(d("0 6 * jan,jul mon"), "At 06:00 on Monday in January and July");
        assert_eq!(d("@at 2026-11-05 09:00"), "Once, on Thu 5 Nov 2026 at 09:00");
        assert_eq!(d("1,7 9 * * *"), "Custom cron schedule");
    }
}
