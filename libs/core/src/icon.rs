//! A job's icon: an SVG drawing that the menu bar app shows next to the job.
//!
//! The daemon keeps a cleaned copy in the job. `clean_svg` keeps only what
//! draws: allowed elements (`ALLOWED`) with allowed attributes
//! (`ATTRIBUTES`). Everything else goes, with what it holds: scripts,
//! `<foreignObject>`, `<image>`, `<set>` and `<animate>`, event attributes,
//! links (`href` to anything but `#id`), comments, `<!DOCTYPE>` with its
//! entities. A value or a `<style>` that could load a file is dropped: one
//! with `url()` to anything but `#id`, `@`, a backslash (a CSS escape), an
//! entity, `image-set` or `expression`.

/// The largest icon, before cleaning.
pub const MAX_ICON_BYTES: usize = 64 * 1024;

/// Elements that are kept, in lower case. Any other element is removed
/// with everything in it; `<a>` loses only its own tags.
const ALLOWED: [&str; 22] = [
    "svg", "g", "path", "circle", "rect", "ellipse", "line", "polyline", "polygon", "defs", "lineargradient",
    "radialgradient", "stop", "use", "title", "desc", "clippath", "mask", "symbol", "text", "tspan", "style",
];

/// Attributes that are kept, in lower case.
const ATTRIBUTES: [&str; 64] = [
    "id", "class", "style", "d", "x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry", "fx", "fy", "width",
    "height", "viewbox", "preserveaspectratio", "points", "transform", "fill", "fill-opacity", "fill-rule", "clip-rule",
    "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray",
    "stroke-dashoffset", "stroke-opacity", "opacity", "color", "display", "visibility", "overflow", "clip-path", "mask",
    "gradientunits", "gradienttransform", "spreadmethod", "offset", "stop-color", "stop-opacity", "clippathunits",
    "maskunits", "maskcontentunits", "vector-effect", "font-family", "font-size", "font-weight", "text-anchor",
    "dominant-baseline", "letter-spacing", "xmlns", "xmlns:xlink", "version", "href", "xlink:href", "xml:space",
];

/// Checks an SVG drawing and returns it without the parts that run code or
/// load files. An error says why the text is not an icon.
pub fn clean_svg(text: &str) -> Result<String, String> {
    if text.len() > MAX_ICON_BYTES {
        return Err(format!("the icon is {} KB; it may be at most {} KB", text.len().div_ceil(1024), MAX_ICON_BYTES / 1024));
    }
    let mut out = String::with_capacity(text.len());
    // While inside a dropped element: its name and the depth of nested
    // elements of the same name.
    let mut dropping: Option<(String, usize)> = None;
    let mut saw_svg = false;
    let mut in_style = false;
    let mut rest = text;
    while let Some(start) = rest.find('<') {
        if dropping.is_none() {
            out.push_str(&rest[..start]);
        }
        rest = &rest[start..];
        if let Some(after) = rest.strip_prefix("<!--") {
            rest = after.find("-->").map_or("", |end| &after[end + 3..]);
        } else if rest.starts_with("<![CDATA[") {
            // Only a <style> may hold one, and its text was checked.
            let end = rest.find("]]>").map_or(rest.len(), |e| e + 3);
            if dropping.is_none() && in_style {
                out.push_str(&rest[..end]);
            }
            rest = &rest[end..];
        } else if rest.starts_with("<!") {
            rest = &rest[declaration_end(rest)..];
        } else if let Some(after) = rest.strip_prefix("<?") {
            rest = after.find("?>").map_or("", |end| &after[end + 2..]);
        } else {
            let end = tag_end(rest).ok_or("the icon is not valid SVG: a tag is not closed with >")?;
            let Some(tag) = Tag::parse(&rest[..end]) else {
                // A lone '<' in text: keep it escaped.
                if dropping.is_none() {
                    out.push_str("&lt;");
                }
                rest = &rest[1..];
                continue;
            };
            rest = &rest[end..];
            if let Some((name, depth)) = &mut dropping {
                if tag.name == *name {
                    if tag.closing {
                        *depth -= 1;
                    } else if !tag.self_closing {
                        *depth += 1;
                    }
                    if *depth == 0 {
                        dropping = None;
                    }
                }
                continue;
            }
            // A link: keep what it holds, without the link.
            if tag.name == "a" {
                continue;
            }
            if !ALLOWED.contains(&tag.name.as_str()) {
                if !tag.closing && !tag.self_closing {
                    dropping = Some((tag.name.clone(), 1));
                }
                continue;
            }
            if tag.name == "style" && !tag.closing && !tag.self_closing {
                let close = rest.to_ascii_lowercase().find("</style").unwrap_or(rest.len());
                if !safe_value(&rest[..close]) {
                    dropping = Some(("style".into(), 1));
                    continue;
                }
                in_style = true;
            }
            if tag.name == "style" && tag.closing {
                in_style = false;
            }
            if tag.name == "svg" && !tag.closing {
                saw_svg = true;
            }
            out.push_str(&tag.render());
        }
    }
    if dropping.is_none() {
        out.push_str(rest);
    }
    if !saw_svg {
        return Err("the icon is not an SVG drawing: it has no <svg> element".into());
    }
    Ok(out.trim().to_string())
}

/// CSS or an attribute value that cannot load a file: every `url(` points
/// to an element of the drawing (`url(#id)`), and nothing could hide one:
/// no CSS escape (`\`), at-rule (`@import`), entity (`&#104;`),
/// `image-set` or `expression`.
fn safe_value(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    if ['\\', '@', '&'].iter().any(|c| lower.contains(*c)) || lower.contains("image-set") || lower.contains("expression") {
        return false;
    }
    lower.match_indices("url(").all(|(i, _)| lower[i + 4..].trim_start_matches([' ', '"', '\'']).starts_with('#'))
}

/// The end of `<!DOCTYPE ...>`, after a `[...]` internal subset.
fn declaration_end(text: &str) -> usize {
    let mut in_subset = false;
    for (i, c) in text.char_indices() {
        match c {
            '[' => in_subset = true,
            ']' => in_subset = false,
            '>' if !in_subset => return i + 1,
            _ => {}
        }
    }
    text.len()
}

/// The index after the `>` that closes the tag at the start of `text`. A
/// `>` inside a quoted attribute value does not close it.
fn tag_end(text: &str) -> Option<usize> {
    let mut quote: Option<char> = None;
    for (i, c) in text.char_indices().skip(1) {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (Some(_), _) => {}
            (None, '"' | '\'') => quote = Some(c),
            (None, '>') => return Some(i + 1),
            // Text such as "a < b": the '<' does not start a tag.
            (None, '<') => return Some(1),
            _ => {}
        }
    }
    None
}

struct Tag {
    /// Lower case, without a namespace prefix: `svg:script` is `script`.
    name: String,
    /// The name as written.
    raw_name: String,
    closing: bool,
    self_closing: bool,
    attributes: Vec<(String, Option<String>)>,
}

impl Tag {
    /// None when the text is not a tag: `<` followed by a space.
    fn parse(text: &str) -> Option<Tag> {
        let inner = text.strip_prefix('<')?.strip_suffix('>')?;
        let (closing, inner) = match inner.strip_prefix('/') {
            Some(i) => (true, i),
            None => (false, inner),
        };
        let (self_closing, inner) = match inner.trim_end().strip_suffix('/') {
            Some(i) => (true, i),
            None => (false, inner),
        };
        let name_len = inner.find(|c: char| c.is_whitespace()).unwrap_or(inner.len());
        let raw_name = &inner[..name_len];
        if raw_name.is_empty() || !raw_name.chars().all(|c| c.is_ascii_alphanumeric() || "-_:.".contains(c)) {
            return None;
        }
        let local = raw_name.rsplit(':').next().unwrap_or(raw_name);
        Some(Tag {
            name: local.to_ascii_lowercase(),
            raw_name: raw_name.to_string(),
            closing,
            self_closing,
            attributes: parse_attributes(&inner[name_len..]),
        })
    }

    fn render(&self) -> String {
        if self.closing {
            return format!("</{}>", self.raw_name);
        }
        let mut s = format!("<{}", self.raw_name);
        for (name, value) in &self.attributes {
            if !keep_attribute(name, value.as_deref()) {
                continue;
            }
            if let Some(v) = value {
                s.push_str(&format!(" {name}=\"{}\"", v.replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")));
            }
        }
        s.push_str(if self.self_closing { "/>" } else { ">" });
        s
    }
}

/// An allowed name with a value that loads nothing. `href` only points to
/// an element of the drawing.
fn keep_attribute(name: &str, value: Option<&str>) -> bool {
    let lower = name.to_ascii_lowercase();
    let Some(value) = value else { return false };
    if !ATTRIBUTES.contains(&lower.as_str()) {
        return false;
    }
    if lower == "href" || lower == "xlink:href" {
        return value.trim_start().starts_with('#') && !value.contains(['&', '\\']);
    }
    lower.starts_with("xmlns") || safe_value(value)
}

/// `a="1" b='2' c=3 d` as pairs; a value keeps its text as written.
fn parse_attributes(text: &str) -> Vec<(String, Option<String>)> {
    let mut out = Vec::new();
    let mut chars = text.char_indices().peekable();
    let at = |i: Option<&(usize, char)>| i.map_or(text.len(), |(i, _)| *i);
    loop {
        while chars.next_if(|(_, c)| c.is_whitespace()).is_some() {}
        let start = at(chars.peek());
        while chars.next_if(|(_, c)| !c.is_whitespace() && *c != '=').is_some() {}
        let name = &text[start..at(chars.peek())];
        if name.is_empty() {
            // A stray '=' or the end.
            if chars.next().is_none() {
                return out;
            }
            continue;
        }
        while chars.next_if(|(_, c)| c.is_whitespace()).is_some() {}
        if chars.next_if(|(_, c)| *c == '=').is_none() {
            out.push((name.to_string(), None));
            continue;
        }
        while chars.next_if(|(_, c)| c.is_whitespace()).is_some() {}
        let value = match chars.peek().map(|(_, c)| *c) {
            Some(q @ ('"' | '\'')) => {
                chars.next();
                let from = at(chars.peek());
                while chars.next_if(|(_, c)| *c != q).is_some() {}
                let v = &text[from..at(chars.peek())];
                chars.next();
                v
            }
            _ => {
                let from = at(chars.peek());
                while chars.next_if(|(_, c)| !c.is_whitespace()).is_some() {}
                &text[from..at(chars.peek())]
            }
        };
        out.push((name.to_string(), Some(value.to_string())));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FLAG: &str = r##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M3.5 2.4h9l-2.2 3.1 2.2 3.1h-9z" fill="#E5484D"/></svg>"##;

    #[test]
    fn a_plain_drawing_stays_as_it_is() {
        assert_eq!(clean_svg(FLAG).unwrap(), FLAG);
    }

    #[test]
    fn scripts_events_and_links_are_removed() {
        let svg = r##"<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/passwd">]><!-- made by hand -->
<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)" viewBox="0 0 16 16">
<script type="text/javascript">alert("<svg>")</script>
<a href="https://example.com"><circle cx="8" cy="8" r="3" onclick='steal()'/></a>
<use xlink:href="#dot"/><use href="https://example.com/x.svg#a"/>
<foreignObject><div><foreignObject>nested</foreignObject></div></foreignObject>
<image href="https://example.com/track.png"/>
<rect style="fill:url(https://example.com/a)" fill="url(#grad)" width="2" height="2"/>
</svg>"##;
        let clean = clean_svg(svg).unwrap();
        for gone in ["<?xml", "DOCTYPE", "ENTITY", "made by hand", "onload", "script", "alert", "onclick", "example.com", "<a", "</a>", "foreignObject", "nested", "<image"] {
            assert!(!clean.contains(gone), "{gone} is still in:\n{clean}");
        }
        for kept in [r##"<use xlink:href="#dot"/>"##, r#"<circle cx="8" cy="8" r="3"/>"#, r##"fill="url(#grad)""##, "<use/>"] {
            assert!(clean.contains(kept), "{kept} is missing in:\n{clean}");
        }
        assert!(clean.starts_with("<svg") && clean.ends_with("</svg>"), "{clean}");
    }

    #[test]
    fn a_style_that_loads_a_file_is_removed_and_one_that_does_not_stays() {
        let kept = clean_svg(r#"<svg><style>.a{fill:#E5484D}</style><path class="a"/></svg>"#).unwrap();
        assert_eq!(kept, r#"<svg><style>.a{fill:#E5484D}</style><path class="a"/></svg>"#);
        let dropped = clean_svg(r#"<svg><style>@import url(https://example.com/a.css);</style><path/></svg>"#).unwrap();
        assert_eq!(dropped, "<svg><path/></svg>");
    }

    #[test]
    fn a_greater_than_sign_in_a_value_does_not_end_the_tag() {
        let svg = r#"<svg><text font-family="a>b">1 &lt; 2</text></svg>"#;
        assert_eq!(clean_svg(svg).unwrap(), r#"<svg><text font-family="a&gt;b">1 &lt; 2</text></svg>"#);
    }

    #[test]
    fn elements_and_attributes_that_are_not_allowed_go() {
        let svg = r##"<svg viewBox="0 0 16 16" data-x="1" sodipodi:docname="a.svg">
<set attributeName="href" to="https://example.com/a"/>
<animate attributeName="fill" values="url(https://example.com/a)"><animate/></animate>
<filter><feImage href="https://example.com/a"/></filter>
<svg:script>x()</svg:script>
<metadata><rdf:RDF>made in Inkscape</rdf:RDF></metadata>
<path d="M0 0h9" fill="url(&#104;ttps://example.com/a)" stroke="#000"/>
<rect style="fill:u\rl(https://example.com/a)" width="2"/>
<circle style="fill:image-set('https://example.com/a' 1x)" r="2"/>
<use href="&#35;x"/>
<![CDATA[<script>x()</script>]]>
</svg>"##;
        let clean = clean_svg(svg).unwrap();
        for gone in ["data-x", "sodipodi", "<set", "animate", "filter", "feImage", "script", "metadata", "Inkscape", "example.com",
                     "&#", "CDATA", "u\\rl", "image-set"] {
            assert!(!clean.contains(gone), "{gone} is still in:\n{clean}");
        }
        for kept in [r##"<path d="M0 0h9" stroke="#000"/>"##, r#"<rect width="2"/>"#, r#"<circle r="2"/>"#, "<use/>"] {
            assert!(clean.contains(kept), "{kept} is missing in:\n{clean}");
        }
    }

    #[test]
    fn a_style_that_could_hide_a_url_is_removed() {
        for css in [r".a{fill:u\72 l(https://example.com/a)}", ".a{fill:url(&#104;ttps://example.com)}", "@font-face{src:url(x)}"] {
            let clean = clean_svg(&format!("<svg><style>{css}</style><path/></svg>")).unwrap();
            assert_eq!(clean, "<svg><path/></svg>", "{css}");
        }
        let kept = clean_svg("<svg><style><![CDATA[.a{fill:url(#g)}]]></style></svg>").unwrap();
        assert_eq!(kept, "<svg><style><![CDATA[.a{fill:url(#g)}]]></style></svg>");
    }

    #[test]
    fn text_that_is_not_an_svg_is_refused() {
        assert!(clean_svg("<html><body/></html>").unwrap_err().contains("no <svg>"));
        assert!(clean_svg("just text").unwrap_err().contains("no <svg>"));
        assert!(clean_svg("<svg").unwrap_err().contains("not closed"));
        // Only a script: nothing is left of the drawing.
        assert!(clean_svg("<script><svg></svg></script>").unwrap_err().contains("no <svg>"));
    }

    #[test]
    fn an_icon_over_64_kb_is_refused() {
        let big = format!("<svg>{}</svg>", " ".repeat(MAX_ICON_BYTES));
        assert!(clean_svg(&big).unwrap_err().contains("at most 64 KB"));
    }
}
