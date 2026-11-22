//! What a screen reader and an agent are told of the page, whole, in the states that matter, against
//! goldens (`src/program/reading/<state>.txt`; `PENCERE_BLESS=1` writes them, `READING_OUT` names a folder
//! each reading is copied to), and the reading audit of each: a control with no name or no id, an item said
//! twice.
//!
//! The page is opened by the page tests' own rig (`super::Rig`), which has no `pencere-drive`; the
//! reading is therefore written here from what the kit tells a screen reader (`Laid::accessible`),
//! in the lines `Reading::text` writes: a reference, the role, the words, the state.

use std::fmt::Write as _;
use std::path::PathBuf;

use super::*;

/// The reference of an element: six hexadecimal digits of its number, or blanks where it has none.
fn reference(id: Option<Id>) -> String {
    match id {
        Some(id) => format!("{:06x} ", (id.number() >> 24) & 0xff_ffff),
        None => "       ".to_owned(),
    }
}

/// Words with what is not a word taken out, a line break kept and indented under its line.
fn clean(text: &str) -> String {
    text.chars()
        .take(200)
        .map(|c| match c {
            '\t' => ' ',
            c if c != '\n' && c.is_control() => '?',
            c => c,
        })
        .collect::<String>()
        .replace('\n', "\n        ")
}

fn role_of(role: pencere_view::AccessibleRole) -> String {
    use pencere_view::AccessibleRole as Role;
    match role {
        Role::Heading(level) => format!("heading{level}"),
        Role::Field(_) => "field".to_owned(),
        other => format!("{other:?}").to_lowercase(),
    }
}

/// What the rig's page says to a screen reader now, one line to an element.
fn reading(rig: &Rig) -> String {
    let mut out = String::new();
    let items = rig.laid.accessible();
    out.push_str("items:\n");
    for item in &items {
        let mut parts: Vec<String> = Vec::new();
        match item.state.checked {
            Some(true) => parts.push("checked".to_owned()),
            Some(false) => parts.push("unchecked".to_owned()),
            None => {}
        }
        if item.state.selected {
            parts.push("selected".to_owned());
        }
        match item.state.expanded {
            Some(true) => parts.push("expanded".to_owned()),
            Some(false) => parts.push("collapsed".to_owned()),
            None => {}
        }
        if item.state.disabled {
            parts.push("disabled".to_owned());
        }
        if let Some(value) = &item.state.value {
            parts.push(format!("value \"{}\"", clean(value)));
        }
        let state = if parts.is_empty() {
            String::new()
        } else {
            format!(" [{}]", parts.join(", "))
        };
        let _ = writeln!(
            out,
            "{}{} \"{}\"{state}",
            reference(item.id),
            role_of(item.role),
            clean(&item.words)
        );
    }
    let fields = rig.laid.fields();
    if !fields.is_empty() {
        out.push_str("fields:\n");
    }
    for field in &fields {
        let label = field
            .label
            .as_deref()
            .or(field.hint.as_deref())
            .unwrap_or_default();
        let _ = writeln!(
            out,
            "{}field \"{}\"{}",
            reference(Some(field.id)),
            clean(label),
            if field.covered { " (covered)" } else { "" }
        );
    }
    // The statement editor: the lines of its text, as the reading of an editor gives them.
    out.push_str("editors:\n");
    let _ = writeln!(out, "{}editor \"sql\"", reference(Some(Id::named(SQL))));
    for (at, line) in rig.text().lines().enumerate().take(60) {
        let _ = writeln!(out, "  {:>2}| {}", at + 1, clean(line));
    }
    out
}

/// What is wrong with the reading, a line each, as `pencere_drive::audit` finds it (this rig has no
/// `pencere-drive`): a control with no name, one with no id, an item said again by the one after it.
fn flaws(rig: &Rig) -> String {
    use pencere_view::AccessibleRole as Role;
    let items = rig.laid.accessible();
    let mut found = String::new();
    for (at, item) in items.iter().enumerate() {
        let control = item.pressable
            || matches!(
                item.role,
                Role::Button
                    | Role::Link
                    | Role::Checkbox
                    | Role::Switch
                    | Role::Radio
                    | Role::Tab
                    | Role::MenuItem
                    | Role::Slider
            );
        let words = item.words.trim();
        if control && words.is_empty() {
            let _ = writeln!(found, "item {at}: nameless: {:?}", item.role);
        }
        if control && item.id.is_none() {
            let _ = writeln!(found, "item {at}: no id: {:?} \"{words}\"", item.role);
        }
        if at > 0 && !words.is_empty() && items[at - 1].words.trim() == words {
            // A heading that names the dialog it is in is read after it: no repeat.
            let titles = item.parent == Some(at - 1) && matches!(item.role, Role::Heading(_));
            if !titles {
                let _ = writeln!(found, "item {at}: said twice: {:?} \"{words}\"", item.role);
            }
        }
    }
    found
}

/// Sets what the page reads now against the golden `name`, and holds it to the audit above.
fn check(name: &str, rig: &Rig) {
    // How long a statement took is the machine's, not the page's: it is not part of what is read.
    let text: String = reading(rig)
        .split_inclusive('\n')
        .map(|line| {
            let words = line.trim();
            match words
                .strip_prefix("text \"")
                .and_then(|rest| rest.strip_suffix(" ms\""))
            {
                Some(number)
                    if number.chars().all(|c| c.is_ascii_digit()) && !number.is_empty() =>
                {
                    let indent = &line[..line.len() - line.trim_start().len()];
                    format!("{indent}text \"# ms\"\n")
                }
                _ => line.to_owned(),
            }
        })
        .collect();
    if let Some(dir) = std::env::var_os("READING_OUT") {
        let dir = PathBuf::from(dir);
        std::fs::create_dir_all(&dir).expect("a folder for the readings");
        std::fs::write(dir.join(format!("{name}.txt")), &text).expect("a reading");
    }
    let file = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("src/program/reading")
        .join(format!("{name}.txt"));
    if std::env::var_os("PENCERE_BLESS").is_some() {
        std::fs::create_dir_all(file.parent().expect("a folder"))
            .expect("a folder for the goldens");
        std::fs::write(&file, &text).expect("a golden");
    } else {
        let golden = std::fs::read_to_string(&file)
            .unwrap_or_else(|_| panic!("{name}: no golden at {}: PENCERE_BLESS=1", file.display()));
        assert_eq!(
            golden, text,
            "{name}: the page is read otherwise than the golden says: PENCERE_BLESS=1 writes it"
        );
    }
    let found = flaws(rig);
    assert!(
        found.is_empty(),
        "{name}: the reading audit finds:\n{found}"
    );
}

#[test]
#[ignore = "page: compiles the kit's interpreter and drives the page; make test-page"]
fn the_page_is_read_in_its_states() {
    // The page as it opens: the editor, the tables, the status bar.
    let mut rig = Rig::open(WIDE);
    check("main", &rig);

    // The completions open under the caret.
    let end = rig.text().len();
    rig.caret_to(end);
    rig.type_letters("select * from ord");
    assert!(rig.says("orders"), "{:?}", rig.words());
    check("completions", &rig);

    // A plan: the steps of how the statement would run.
    let mut rig = Rig::open(WIDE);
    let at = rig.text().find("select c.country").unwrap() + 3;
    rig.caret_to(at);
    rig.command("explain");
    assert!(rig.says("Plan"), "{:?}", rig.words());
    check("plan", &rig);

    // A mistake the database points at: the banner and the mark.
    let mut rig = Rig::open(WIDE);
    let end = rig.text().len();
    rig.caret_to(end);
    rig.type_text("select nme from customers;");
    rig.command("run");
    assert!(rig.says("It did not run"), "{:?}", rig.words());
    check("mistake", &rig);

    // A table's rows in the grid, a cell chosen, a value opened whole over the page, and the toast
    // that its copy raises over the value.
    let mut rig = Rig::open(WIDE);
    rig.press("table:main.events", 2);
    assert!(rig.says("payload"), "{:?}", rig.words());
    check("rows", &rig);
    rig.press_at_column("row:1", 2, 1);
    check("cell-chosen", &rig);
    rig.press_at_column("row:1", 4, 2);
    assert!(rig.says("session"), "{:?}", rig.words());
    check("value", &rig);
    rig.press("inspect-copy", 1);
    assert!(rig.says("Copied the value"), "{:?}", rig.words());
    check("value-toast", &rig);

    // A small table's rows sorted up, then down, by the header of a column. On a page of its own:
    // a toast of the states before would still be on this one, for as long as the page's clock says.
    let mut rig = Rig::open(WIDE);
    rig.press("table:main.products", 2);
    assert!(rig.says("Results"), "{:?}", rig.words());
    rig.press("head:2", 1);
    check("sorted-up", &rig);
    rig.press("head:2", 1);
    check("sorted-down", &rig);

    // The rows copied: a toast over the page, with no modal behind it.
    rig.press("copy", 1);
    assert!(rig.says("Copied"), "{:?}", rig.words());
    check("copied", &rig);

    // An 80 by 24 pane: no list of tables, the results under the editor.
    let mut narrow = Rig::open(NARROW);
    let at = narrow
        .text()
        .find("select * from revenue_by_month")
        .unwrap()
        + 3;
    narrow.caret_to(at);
    narrow.command("run");
    assert!(narrow.says("month"), "{:?}", narrow.words());
    check("narrow", &narrow);
}
