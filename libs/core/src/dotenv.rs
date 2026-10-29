//! Reading one variable from the text of a `.env` file, for
//! `localcron secret set NAME --key KEY`. The text may come from a file, a
//! named pipe (1Password Environments mounts `.env` files as pipes) or stdin.
//!
//! The usual dotenv forms: `KEY=value`, `export KEY=value`, `# comments`,
//! `KEY="double quoted\n"` (with `\n`, `\t`, `\"` and `\\`), `KEY='single
//! quoted'` (as written), and a ` # comment` after an unquoted value. A quoted
//! value may span lines. The last line for a key wins.
//!
//! Errors never contain a value: only key names.

/// The value of `key`, or why there is none.
pub fn lookup(text: &str, key: &str) -> Result<String, String> {
    let mut found = None;
    for (k, v) in parse(text)? {
        if k == key {
            found = Some(v);
        }
    }
    match found {
        Some(v) if v.is_empty() => Err(format!("{key} is empty in the .env")),
        Some(v) => Ok(v),
        None => {
            let mut names: Vec<String> = parse(text)?.into_iter().map(|(k, _)| k).collect();
            names.sort();
            names.dedup();
            if names.is_empty() {
                Err(format!("{key} is not in the .env: it has no variables"))
            } else {
                Err(format!("{key} is not in the .env; it has {}", names.join(", ")))
            }
        }
    }
}

/// Every `KEY=value` in order.
fn parse(text: &str) -> Result<Vec<(String, String)>, String> {
    let mut out = Vec::new();
    let mut pos = 0;
    while pos < text.len() {
        let line_no = text[..pos].matches('\n').count() + 1;
        let line_end = text[pos..].find('\n').map_or(text.len(), |i| pos + i);
        let line = &text[pos..line_end];
        let trimmed = line.trim_start();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            pos = line_end + 1;
            continue;
        }
        let body = trimmed.strip_prefix("export ").map(str::trim_start).unwrap_or(trimmed);
        let Some((key, value)) = body.split_once('=') else {
            return Err(format!("line {line_no} of the .env has no '='"));
        };
        let key = key.trim().to_string();
        let value = value.trim_start();
        match value.chars().next() {
            Some(quote @ ('"' | '\'')) => {
                // `value` ends the line, so its start is known; a quoted
                // value may go on over later lines.
                let open = line_end - value.len();
                let (v, used) =
                    quoted(&text[open + 1..], quote).ok_or_else(|| format!("line {line_no} of the .env: {key} has no closing {quote}"))?;
                out.push((key, v));
                let close = open + 1 + used;
                pos = text[close..].find('\n').map_or(text.len(), |i| close + i + 1);
            }
            _ => {
                let v = value.find(" #").map_or(value, |i| &value[..i]);
                out.push((key, v.trim_end().to_string()));
                pos = line_end + 1;
            }
        }
    }
    Ok(out)
}

/// The value inside quotes that start `text` after the opening quote, and
/// how many bytes it used, the closing quote included.
fn quoted(text: &str, quote: char) -> Option<(String, usize)> {
    let mut value = String::new();
    let mut chars = text.char_indices();
    while let Some((i, c)) = chars.next() {
        match c {
            c if c == quote => return Some((value, i + 1)),
            '\\' if quote == '"' => match chars.next()?.1 {
                'n' => value.push('\n'),
                'r' => value.push('\r'),
                't' => value.push('\t'),
                other => value.push(other),
            },
            c => value.push(c),
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    const ENV: &str = "# made by 1Password\n\
        export GH_TOKEN=ghp_abc123\n\
        OPENAI_API_KEY = sk-xyz # the old one\n\
        \n\
        QUOTED=\"a b\\n\\\"c\\\"\"\n\
        SINGLE='keep \\n as is'\n\
        PEM=\"-----BEGIN-----\n\
        line two\n\
        -----END-----\"\n\
        AFTER=yes\n\
        EMPTY=\n\
        GH_TOKEN=ghp_newer\r\n";

    #[test]
    fn values_in_their_forms() {
        assert_eq!(lookup(ENV, "OPENAI_API_KEY").unwrap(), "sk-xyz");
        assert_eq!(lookup(ENV, "QUOTED").unwrap(), "a b\n\"c\"");
        assert_eq!(lookup(ENV, "SINGLE").unwrap(), "keep \\n as is");
        assert_eq!(lookup(ENV, "PEM").unwrap(), "-----BEGIN-----\nline two\n-----END-----");
        assert_eq!(lookup(ENV, "AFTER").unwrap(), "yes", "the line after a quoted value spanning lines");
    }

    #[test]
    fn the_last_line_wins_and_crlf_is_cut() {
        assert_eq!(lookup(ENV, "GH_TOKEN").unwrap(), "ghp_newer");
    }

    #[test]
    fn errors_name_keys_never_values() {
        let e = lookup(ENV, "NOPE").unwrap_err();
        assert!(e.starts_with("NOPE is not in the .env; it has AFTER, EMPTY, GH_TOKEN"), "{e}");
        assert!(!e.contains("ghp_") && !e.contains("sk-"), "{e}");
        assert_eq!(lookup(ENV, "EMPTY").unwrap_err(), "EMPTY is empty in the .env");
        assert!(lookup("", "A").unwrap_err().contains("no variables"));
        assert!(lookup("A=\"open\n", "A").unwrap_err().contains("no closing"));
        assert!(lookup("just words\n", "A").unwrap_err().contains("line 1"));
    }
}
