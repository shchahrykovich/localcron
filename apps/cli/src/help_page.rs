//! `localcron help-page`: the help as one HTML file, with nothing to load
//! from the network. The app build writes it into the bundle
//! (`Contents/Resources/help.html`); the app opens it in the default browser.
//! The page keeps the Markdown too, for its Copy as Markdown button.

use localcron_core::help;
use localcron_core::instance::Instance;

pub fn render(instance: &Instance) -> anyhow::Result<String> {
    let markdown = help::render(instance);
    let body = markdown::to_html_with_options(&markdown, &markdown::Options::gfm()).map_err(|e| anyhow::anyhow!("{e}"))?;
    Ok(TEMPLATE.replace("{{TITLE}}", &escape(&format!("{} help", instance.app_name())))
        .replace("{{VERSION}}", help::VERSION)
        .replace("{{BODY}}", &body)
        .replace("{{MARKDOWN}}", &escape(&markdown)))
}

/// For text inside an element: `<textarea>` gives it back unescaped.
fn escape(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

const TEMPLATE: &str = r#"<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{TITLE}}</title>
<style>
:root { --bg: #fff; --text: #1d1d1f; --muted: #6e6e73; --line: #d2d2d7; --code: #f5f5f7; --accent: #0071e3; color-scheme: light dark; }
@media (prefers-color-scheme: dark) { :root { --bg: #1c1c1e; --text: #f5f5f7; --muted: #a1a1a6; --line: #3a3a3c; --code: #2c2c2e; --accent: #2997ff; } }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
header { position: sticky; top: 0; display: flex; gap: 12px; align-items: center; padding: 10px 24px; background: var(--bg); border-bottom: 1px solid var(--line); }
header strong { flex: 1; }
button { font: inherit; padding: 5px 14px; border-radius: 6px; border: 1px solid var(--line); background: var(--code); color: var(--text); cursor: pointer; }
button:hover { border-color: var(--accent); }
#status, #version { color: var(--muted); font-size: 13px; font-weight: normal; }
main { max-width: 860px; margin: 0 auto; padding: 8px 24px 64px; }
h1 { font-size: 28px; margin: 24px 0 8px; }
h2 { font-size: 21px; margin: 36px 0 8px; padding-top: 12px; border-top: 1px solid var(--line); }
h3 { font-size: 17px; margin: 24px 0 6px; }
a { color: var(--accent); }
code { font: 13px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--code); padding: 1px 5px; border-radius: 4px; }
pre { background: var(--code); padding: 12px 14px; border-radius: 8px; overflow-x: auto; }
pre code { padding: 0; background: none; }
table { border-collapse: collapse; width: 100%; margin: 8px 0; font-size: 14px; }
th, td { text-align: left; vertical-align: top; padding: 6px 10px; border-bottom: 1px solid var(--line); }
th { color: var(--muted); font-weight: 600; }
textarea { position: absolute; left: -9999px; }
</style>
</head>
<body>
<header>
  <strong>{{TITLE}} <span id="version">{{VERSION}}</span></strong>
  <span id="status" role="status"></span>
  <a href="https://github.com/shchahrykovich/localcron">GitHub</a>
  <button id="copy" type="button">Copy as Markdown</button>
</header>
<main>
{{BODY}}
</main>
<textarea id="markdown" readonly aria-hidden="true">{{MARKDOWN}}</textarea>
<script>
const source = document.getElementById("markdown");
const status = document.getElementById("status");
function done(ok) {
  status.textContent = ok ? "Copied. Paste it into your agent." : "Could not copy: select the page text instead.";
  setTimeout(() => { status.textContent = ""; }, 4000);
}
document.getElementById("copy").addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(source.value);
    done(true);
  } catch (e) {
    // A file:// page may not get the clipboard API in every browser.
    source.select();
    done(document.execCommand("copy"));
  }
});
</script>
</body>
</html>
"#;

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;

    #[test]
    fn the_page_has_the_markdown_and_names_every_command() {
        let page = render(&Instance::new("-dev").unwrap()).unwrap();
        assert!(page.contains("<title>LocalCron-dev help</title>"));
        assert!(page.contains(&format!(r#"<span id="version">{}</span>"#, help::VERSION)));
        assert!(page.contains("Copy as Markdown"));
        // Rendered: a table, a code block; kept: the Markdown, escaped.
        assert!(page.contains("<table>") && page.contains("<pre><code"));
        assert!(page.contains("## Instructions for agents"));
        assert!(page.contains("&lt;secret NAME&gt;"));
        // The link in the header and in the Markdown that Copy as Markdown copies.
        assert!(page.contains(r#"<a href="https://github.com/shchahrykovich/localcron">GitHub</a>"#));
        assert!(page.contains("&lt;https://github.com/shchahrykovich/localcron&gt;"));
        assert!(!page.contains("{{"), "a placeholder is left");
        // Every command a person can type is explained.
        for sub in crate::Cli::command().get_subcommands().filter(|c| !c.is_hide_set()) {
            let name = sub.get_name();
            assert!(page.contains(&format!("localcron-dev {name}")), "the help does not explain `{name}`");
        }
    }
}
