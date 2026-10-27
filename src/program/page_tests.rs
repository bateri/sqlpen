//! The page (src/view/), run as a terminal runs it: in the kit's interpreter, laid out with the kit's
//! editors, its calls answered by the program's own [`App`] over the demo's database. What it shows
//! is read as words; what the person does is done to it as a terminal does it.

use std::path::PathBuf;
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use pencere_editor::{EditorEvent, Editors, Route};
use pencere_sandbox::{Assets, Module, ModuleLimits, Script, Unbounded, Update};
use pencere_view::edit::TextSnapshot;
use pencere_view::wire::Kind;
use pencere_view::{
    Element, Event, Font, Id, Input, Key, Keyboard, Laid, Measure, Metrics, Mods, Point, Scrolls,
    Size, layout,
};
use serde_json::{Value, json};

use crate::calls::App;
use crate::db::Db;
use crate::db::sqlite::Sqlite;

/// The files of the page as the program carries them: `src/view/` at the top, `src/assets/` under
/// `assets/`.
struct Files(PathBuf);

impl Files {
    fn file(&self, path: &str) -> Option<PathBuf> {
        if path.split('/').any(|part| part == ".." || part.is_empty()) {
            return None;
        }
        let file = match path.strip_prefix("assets/") {
            Some(rest) => self.0.join("src/assets").join(rest),
            None => self.0.join("src/view").join(path),
        };
        file.is_file().then_some(file)
    }
}

impl Assets for Files {
    fn read(&self, path: &str) -> Option<Arc<[u8]>> {
        std::fs::read(self.file(path)?).ok().map(Into::into)
    }

    fn media_type(&self, path: &str) -> Option<String> {
        self.file(path)?;
        let kind = match path.rsplit('.').next()? {
            "lua" | "luau" => "text/x-lua",
            "svg" => "image/svg+xml",
            "png" => "image/png",
            _ => return None,
        };
        Some(kind.to_owned())
    }
}

/// Every character 7 points across, a line 16 high.
struct Fixed;

impl Measure for Fixed {
    fn measure(&mut self, _font: &Font, text: &str) -> Metrics {
        Metrics {
            width: text.chars().count() as f32 * 7.0,
            height: 16.0,
        }
    }
}

struct Rig {
    module: Module,
    woken: Receiver<()>,
    app: App,
    editors: Editors,
    scrolls: Scrolls,
    laid: Arc<Laid>,
    root: Element,
    size: Size,
    now: f64,
    /// What the page sent its program, as it was asked.
    asked: Vec<Value>,
    told: Vec<EditorEvent>,
    /// A frame was asked for and has not come.
    waiting: bool,
    /// When the program last answered, to say how long the page took with it.
    answered: Option<Instant>,
    /// The shape of the pointer the page last asked for, answering the pointer.
    cursor: Option<pencere_view::Cursor>,
}

const SQL: &str = "sql";

impl Rig {
    fn open(size: Size) -> Self {
        Self::open_on(size, Db::Sqlite(Sqlite::demo(false).unwrap()))
    }

    fn open_on(size: Size, db: Db) -> Self {
        Self::open_with(size, db, "")
    }

    /// The page with `options` put in its editor's (for the kit's options of how an editor looks).
    fn open_with(size: Size, db: Db, options: &str) -> Self {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let files = Files(root.clone());
        let page = std::fs::read_to_string(root.join("src/view/page.lua")).unwrap();
        let source = page
            .replacen("padding = 8,", &format!("padding = 8, {options}"), 1)
            .into_bytes();
        let (told, woken) = channel();
        let told = Mutex::new(told);
        let script = Script {
            path: "page.lua".to_owned(),
            source,
            bundle: Some(Arc::new(files)),
        };
        // A call of the page may be held to less than the floor's 250 ms, to see how near it comes.
        let mut limits = ModuleLimits::default();
        if let Some(ms) = std::env::var("SQLPEN_CALL_MS")
            .ok()
            .and_then(|ms| ms.parse().ok())
        {
            limits.call = Duration::from_millis(ms);
        }
        let module = Module::from_script(script, limits, Arc::new(Unbounded), move || {
            let _ = told.lock().map(|told| told.send(()));
        });
        let mut rig = Self {
            module,
            woken,
            app: App::new(db),
            editors: Editors::new(),
            scrolls: Scrolls::new(),
            laid: Arc::new(layout(pencere_view::div(), size, 1.0, &mut Fixed)),
            root: pencere_view::div(),
            size,
            now: 0.0,
            asked: Vec::new(),
            told: Vec::new(),
            waiting: false,
            answered: None,
            cursor: None,
        };
        rig.module.render(size, rig.now, false);
        // The interpreter is compiled before the first page.
        let began = Instant::now();
        loop {
            let _ = rig.woken.recv_timeout(Duration::from_millis(200));
            let update = rig.module.poll();
            let first = update.frame.is_some();
            rig.absorb(update);
            if first {
                break;
            }
            assert!(
                began.elapsed() < Duration::from_secs(60),
                "the page never came"
            );
        }
        rig.run();
        rig
    }

    fn lay_out(&mut self) {
        let mut root = self.root.clone();
        self.scrolls.apply(&mut root);
        let mut laid = layout(root, self.size, 1.0, &mut self.editors.measure(&mut Fixed));
        self.scrolls.place(&mut laid, self.now, false);
        self.editors.sync(&laid, &mut Fixed);
        self.laid = Arc::new(laid);
        self.module.lay_out(Arc::clone(&self.laid));
    }

    fn tell(&mut self) -> bool {
        for ask in self.editors.take_scrolls() {
            self.scrolls.ask(ask);
        }
        let mut busy = false;
        let moved = self.scrolls.take_moved();
        if !moved.is_empty() {
            self.module.event(Event::Scrolled(moved));
            busy = true;
        }
        let events = self.editors.take_events();
        if events.is_empty() {
            return busy;
        }
        let texts = self
            .editors
            .snapshots()
            .into_iter()
            .map(|(id, text)| (id, Arc::new(text) as Arc<dyn TextSnapshot>))
            .collect();
        self.module.texts(texts);
        for event in events {
            self.told.push(event.clone());
            self.module.event(event.into());
        }
        true
    }

    /// The program's answers to what the page asked: the page's own calls, answered at once.
    fn answer(&mut self, sent: &[String]) {
        for text in sent {
            let message: Value = serde_json::from_str(text).unwrap();
            let Some(call) = message.get("call") else {
                continue;
            };
            self.asked.push(call.clone());
            let id = call["id"].clone();
            let method = call["method"].as_str().unwrap_or("");
            let params = call.get("params").cloned().unwrap_or(Value::Null);
            let response = match self.app.call(method, &params, &|| false) {
                Ok(result) => json!({ "response": { "id": id, "result": result } }),
                Err(error) => {
                    json!({ "response": { "id": id, "error": { "code": error.code(), "message": error.message() } } })
                }
            };
            if std::env::var("SQLPEN_DEBUG").is_ok() {
                {
                    let text = response.to_string();
                    eprintln!(
                        "answered {method}: {} bytes, non-ascii {}",
                        text.len(),
                        text.chars().filter(|c| !c.is_ascii()).count()
                    );
                    std::fs::write(format!("/private/tmp/claude-501/-Users-kalaomer-Projects-desktop-apps-bateri-term-pencere/85a17cc4-1d8c-485d-aaab-d534b14b1925/scratchpad/answer-{method}.json"), &text).ok();
                }
            }
            self.answered = Some(Instant::now());
            self.module.message(response.to_string());
        }
    }

    fn absorb(&mut self, update: Update) -> bool {
        if std::env::var("SQLPEN_DEBUG").is_ok() {
            eprintln!(
                "update: frame {} replies {:?} sent {}",
                update.frame.is_some(),
                update
                    .replies
                    .iter()
                    .map(|answer| (answer.reply.redraw, answer.reply.editor.len()))
                    .collect::<Vec<_>>(),
                update.sent.len()
            );
        }
        if let Some(fault) = &update.closed {
            panic!("the page closed: {fault:?}");
        }
        self.answer(&update.sent);
        for ask in &update.asks {
            self.scrolls.ask(*ask);
        }
        let mut busy = !update.sent.is_empty();
        let mut redraw = false;
        let mut relay = false;
        if let Some(frame) = update.frame {
            self.waiting = false;
            self.root = frame.root;
            relay = true;
            busy = true;
        }
        if let (Some(at), false) = (self.answered, update.replies.is_empty()) {
            if std::env::var("SQLPEN_DEBUG").is_ok() {
                eprintln!("page took the answer in {:?}", at.elapsed());
            }
            self.answered = None;
        }
        for answer in update.replies {
            busy = true;
            if answer.pointer {
                self.cursor = Some(answer.reply.cursor);
            }
            redraw |= answer.reply.redraw;
            if let Some(Keyboard::Field(id)) = answer.reply.keyboard {
                self.editors.set_focus(Some(id));
            } else if let Some(Keyboard::Page) = answer.reply.keyboard {
                self.editors.set_focus(None);
            }
            let laid = Arc::clone(&self.laid);
            for (id, ask) in answer.reply.editor {
                if std::env::var("SQLPEN_DEBUG").is_ok() {
                    eprintln!(
                        "ask: {}",
                        format!("{ask:?}").chars().take(300).collect::<String>()
                    );
                }
                self.editors.ask(&laid, id, ask, &mut Fixed, self.now);
            }
        }
        if relay || self.editors.wants_layout() || self.laid.wants_layout() {
            self.lay_out();
        }
        busy |= self.tell();
        if redraw {
            self.now += 0.1;
            self.waiting = true;
            self.module.render(self.size, self.now, false);
        }
        busy || redraw
    }

    /// Goes on as a host does until nothing more comes: answers, frames, the editors' events.
    /// The page is at rest once nothing has come for a while: a page takes its time with what its
    /// program said (a page of rows is read as JSON), and a quiet moment is not yet rest.
    fn run(&mut self) {
        let began = Instant::now();
        let mut quiet = 0;
        while began.elapsed() < Duration::from_secs(30) {
            let _ = self.woken.recv_timeout(Duration::from_millis(150));
            let update = self.module.poll();
            if self.absorb(update) || self.waiting {
                quiet = 0;
            } else {
                quiet += 1;
                if quiet >= 4 {
                    return;
                }
            }
        }
        panic!("the page never came to rest");
    }

    fn command(&mut self, id: &str) {
        self.module.event(Event::Command(Id::named(id)));
        self.run();
    }

    fn key(&mut self, key: Key, mods: Mods) -> Route {
        let laid = Arc::clone(&self.laid);
        let route = self.editors.key(&laid, key, mods, &mut Fixed, self.now);
        match route {
            Route::Command(id) => self.module.event(Event::Command(id)),
            Route::Page | Route::NotEditor => {
                self.module.event(Event::Input(Input::Key { key, mods }))
            }
            _ => {}
        }
        self.run();
        route
    }

    fn type_text(&mut self, text: &str) {
        let laid = Arc::clone(&self.laid);
        self.editors.type_text(&laid, text, &mut Fixed, self.now);
        self.run();
    }

    /// Puts the caret at `at` of the editor's text, as a click there would.
    fn caret_to(&mut self, at: usize) {
        let laid = Arc::clone(&self.laid);
        let ask = pencere_view::edit::EditorAsk::Select {
            ranges: vec![pencere_view::edit::Range {
                anchor: at,
                head: at,
            }],
            version: self.editors.buffer(Id::named(SQL)).unwrap().version(),
            main: 0,
        };
        self.editors
            .ask(&laid, Id::named(SQL), ask, &mut Fixed, self.now);
        self.run();
    }

    /// A picture of the page as it is, drawn twice as large as its points, in `target/shots/`: laid
    /// out again with the system's fonts, the editors drawn in their rooms. What the rig had laid
    /// out (with its fixed measure) is put back after.
    fn shot(&mut self, name: &str) -> PathBuf {
        let root_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let path = root_dir.join("target/shots").join(format!("{name}.png"));
        let mut fonts = crate::shot::Fonts::new(root_dir.join("src"));
        let scale = 2.0;
        let viewport = Size::new(self.size.w * scale, self.size.h * scale);
        // Laid out twice, as a host does when an editor wants it: where a caret is (for what is
        // anchored to it) is known once the editors have laid out their lines in these fonts.
        let mut laid = None;
        for _ in 0..2 {
            let mut root = self.root.clone();
            self.scrolls.apply(&mut root);
            let mut again = layout(root, viewport, scale, &mut self.editors.measure(&mut fonts));
            self.scrolls.place(&mut again, self.now, false);
            self.editors.sync(&again, &mut fonts);
            laid = Some(again);
        }
        let laid = laid.expect("laid out");
        let list = laid.paint(&mut fonts);
        let list = self.editors.paint(list, &mut fonts, true);
        crate::shot::png(
            &list,
            &mut fonts,
            viewport.w as u32,
            viewport.h as u32,
            &root_dir.join("src"),
            &path,
        );
        self.lay_out();
        path
    }

    /// Scrolls the box named `id` down to `y`, as the wheel would, the host telling the page.
    fn scroll(&mut self, id: &str, y: f32) {
        self.scrolls.ask(pencere_view::ScrollTo {
            id: Id::named(id),
            x: None,
            y: Some(y),
            animate: false,
        });
        self.lay_out();
        self.tell();
        self.run();
    }

    /// Folds or unfolds the region the caret is in, as the editor's command does.
    fn fold(&mut self) {
        let laid = Arc::clone(&self.laid);
        let ask =
            pencere_view::edit::EditorAsk::Command(pencere_view::edit::EditCommand::ToggleFold);
        self.editors
            .ask(&laid, Id::named(SQL), ask, &mut Fixed, self.now);
        self.run();
    }

    /// Selects from `from` to `to` of the editor's text.
    fn select(&mut self, from: usize, to: usize) {
        let laid = Arc::clone(&self.laid);
        let ask = pencere_view::edit::EditorAsk::Select {
            ranges: vec![pencere_view::edit::Range {
                anchor: from,
                head: to,
            }],
            version: self.editors.buffer(Id::named(SQL)).unwrap().version(),
            main: 0,
        };
        self.editors
            .ask(&laid, Id::named(SQL), ask, &mut Fixed, self.now);
        self.run();
    }

    /// Types `text` a letter at a time, as a person does.
    fn type_letters(&mut self, text: &str) {
        for letter in text.chars() {
            self.type_text(&letter.to_string());
        }
    }

    fn text(&self) -> String {
        self.editors
            .buffer(Id::named(SQL))
            .expect("the editor")
            .text()
    }

    /// The words of the page as it is now.
    fn words(&self) -> Vec<String> {
        self.root
            .fold()
            .into_iter()
            .filter_map(|node| match node.kind {
                Kind::Text(text) => Some(text),
                _ => None,
            })
            .collect()
    }

    fn says(&self, words: &str) -> bool {
        self.words().iter().any(|text| text.contains(words))
    }

    fn methods(&self) -> Vec<String> {
        self.asked
            .iter()
            .filter_map(|call| call["method"].as_str().map(str::to_owned))
            .collect()
    }

    /// Presses row `id` of the grid in its `column` (from 1).
    fn press_at_column(&mut self, id: &str, column: usize, count: u32) {
        let rect = self
            .laid
            .bounds(Id::named(id))
            .unwrap_or_else(|| panic!("no {id} on the page"));
        // The row's number, then the columns, as wide as the page made them: a column's middle.
        let x = rect.x + 40.0 + (column as f32 - 0.5) * 64.0;
        let at = Point::new(x.min(rect.x + rect.w - 1.0), rect.y + rect.h / 2.0);
        let mods = Mods::default();
        self.module.event(Event::Input(Input::Press {
            at,
            button: pencere_view::Button::Left,
            mods,
            count,
        }));
        self.module.event(Event::Input(Input::Release {
            at,
            button: pencere_view::Button::Left,
        }));
        self.run();
    }

    fn press(&mut self, id: &str, count: u32) {
        let rect = self
            .laid
            .bounds(Id::named(id))
            .unwrap_or_else(|| panic!("no {id} on the page"));
        let at = Point::new(rect.x + rect.w / 2.0, rect.y + rect.h / 2.0);
        let mods = Mods::default();
        self.module.event(Event::Input(Input::Press {
            at,
            button: pencere_view::Button::Left,
            mods,
            count,
        }));
        self.module.event(Event::Input(Input::Release {
            at,
            button: pencere_view::Button::Left,
        }));
        self.run();
    }
}

const WIDE: Size = Size {
    w: 1100.0,
    h: 720.0,
};
/// An 80×24 pane, about.
const NARROW: Size = Size { w: 600.0, h: 330.0 };

fn cmd() -> Mods {
    Mods {
        command: true,
        ..Mods::default()
    }
}

#[test]
#[ignore = "heavy: compiles the kit's interpreter and drives the page for seconds; make test-page"]
fn the_page_opens_on_the_database_with_its_tables_and_a_statement_to_run() {
    let rig = Rig::open(WIDE);
    let methods = rig.methods();
    assert!(
        methods.contains(&"info".to_owned()) && methods.contains(&"schema".to_owned()),
        "{methods:?}"
    );
    assert!(rig.text().contains("select c.country"), "{}", rig.text());
    assert!(
        rig.says("orders") && rig.says("customers"),
        "{:?}",
        rig.words()
    );
    assert!(rig.says("READ ONLY"));
    assert!(rig.root.fold().len() < 20_000);
    // The words of the statement are coloured.
    assert!(
        rig.told
            .iter()
            .any(|event| matches!(event, EditorEvent::Edited { .. }))
    );
}

#[test]
#[ignore = "heavy: compiles the kit's interpreter and drives the page for seconds; make test-page"]
fn the_statement_under_the_caret_runs_and_its_rows_fill_the_grid() {
    let mut rig = Rig::open(WIDE);
    let at = rig.text().find("select c.country").unwrap() + 3;
    rig.caret_to(at);
    let route = rig.key(Key::Enter, cmd());
    assert!(matches!(route, Route::Command(_)), "{route:?}");
    let run = rig
        .asked
        .iter()
        .rev()
        .find(|call| call["method"] == "run")
        .expect("a run");
    assert!(
        run["params"]["sql"]
            .as_str()
            .unwrap()
            .starts_with("select c.country"),
        "{run}"
    );
    assert!(
        run["params"]["sql"]
            .as_str()
            .unwrap()
            .ends_with("order by revenue desc")
    );
    assert!(
        rig.says("Results") && rig.says("country") && rig.says("revenue"),
        "{:?}",
        rig.words()
    );
    assert!(rig.says("TR"));
}

#[test]
#[ignore = "heavy: compiles the kit's interpreter and drives the page for seconds; make test-page"]
fn a_mistake_is_said_and_marked_where_the_database_points() {
    let mut rig = Rig::open(WIDE);
    let end = rig.text().chars().count();
    rig.caret_to(end);
    rig.type_text("select nme from customers;");
    rig.command("run");
    assert!(rig.says("It did not run"), "{:?}", rig.words());
    assert!(rig.says("nme"));
    // The mark is in the editor, on `nme` of the statement.
    let text = rig.text();
    let at = text[..text.rfind("nme").unwrap()].chars().count();
    let buffer = rig.editors.buffer(Id::named(SQL)).unwrap();
    let marked = buffer.decorations_in(at, at + 3);
    assert!(
        marked
            .iter()
            .any(|(_, decoration)| format!("{decoration:?}").contains("Wavy")),
        "{marked:?}"
    );
}

#[test]
#[ignore = "heavy: compiles the kit's interpreter and drives the page for seconds; make test-page"]
fn a_word_is_completed_with_the_databases_own_names() {
    let mut rig = Rig::open(WIDE);
    let end = rig.text().chars().count();
    rig.caret_to(end);
    // A person types a letter at a time.
    for letter in "select * from ord".chars() {
        rig.type_text(&letter.to_string());
    }
    assert!(rig.says("orders"), "{:?}", rig.words());
    assert!(rig.says("Tab or Enter puts it in"), "{:?}", rig.words());
    let route = rig.key(Key::Tab, Mods::default());
    assert!(matches!(route, Route::Command(_)), "{route:?}");
    let text = rig.text();
    assert!(
        text.ends_with("select * from orders"),
        "{:?}",
        &text[text.len().saturating_sub(60)..]
    );
}

#[test]
#[ignore = "heavy: compiles the kit's interpreter and drives the page for seconds; make test-page"]
fn a_plan_shows_its_steps() {
    let mut rig = Rig::open(WIDE);
    let at = rig.text().find("select c.country").unwrap() + 3;
    rig.caret_to(at);
    rig.command("explain");
    assert!(rig.says("Plan"), "{:?}", rig.words());
    assert!(
        rig.words()
            .iter()
            .any(|text| text.starts_with("SCAN") || text.starts_with("SEARCH")),
        "{:?}",
        rig.words()
    );
}

#[test]
#[ignore = "heavy: compiles the kit's interpreter and drives the page for seconds; make test-page"]
fn a_table_double_clicked_shows_its_rows_and_a_cell_opens_whole() {
    let mut rig = Rig::open(WIDE);
    rig.press("table:main.events", 2);
    let run = rig
        .asked
        .iter()
        .rev()
        .find(|call| call["method"] == "run")
        .expect("a run");
    assert_eq!(run["params"]["sql"], "select * from events limit 1000");
    assert!(rig.says("payload"), "{:?}", rig.words());
    rig.press_at_column("row:1", 4, 2);
    assert!(rig.methods().contains(&"cell".to_owned()));
    assert!(rig.says("session"), "{:?}", rig.words());
}

#[test]
#[ignore = "heavy: compiles the kit's interpreter and drives the page for seconds; make test-page"]
fn an_80_by_24_pane_drops_the_list_of_tables_and_still_runs() {
    let mut rig = Rig::open(NARROW);
    assert!(!rig.says("Tables"));
    let at = rig.text().find("select * from revenue_by_month").unwrap() + 3;
    rig.caret_to(at);
    rig.command("run");
    assert!(
        rig.says("month") && rig.says("revenue"),
        "{:?}",
        rig.words()
    );
}

#[test]
#[ignore = "heavy: compiles the kit's interpreter and drives the page for seconds; make test-page"]
fn rows_far_down_a_long_result_are_read_as_they_come_into_view() {
    let mut rig = Rig::open(WIDE);
    rig.press("table:main.events", 2);
    assert!(!rig.methods().contains(&"rows".to_owned()));
    rig.scroll("grid", 24.0 * 700.0);
    let rows = rig
        .asked
        .iter()
        .rev()
        .find(|call| call["method"] == "rows")
        .expect("a read of rows");
    assert!(rows["params"]["from"].as_u64().unwrap() >= 200, "{rows}");
    assert!(rig.says("701"), "{:?}", rig.words());
}

#[test]
#[ignore = "heavy: compiles the kit's interpreter and drives the page for seconds; make test-page"]
fn a_wide_result_comes_in_messages_the_page_reads_in_its_time() {
    let mut rig = Rig::open(WIDE);
    let end = rig.text().chars().count();
    rig.caret_to(end);
    let columns: Vec<String> = (1..=20)
        .map(|n| format!("payload || payload || payload as p{n}"))
        .collect();
    rig.type_text(&format!("select {} from events;", columns.join(", ")));
    rig.command("run");
    assert!(rig.says("p20"), "{:?}", rig.words());
    assert!(!rig.says("Running"), "{:?}", rig.words());
    rig.scroll("grid", 24.0 * 3000.0);
    assert!(rig.says("3001"), "{:?}", rig.words());
}

#[test]
#[ignore = "heavy: compiles the kit's interpreter and drives the page for seconds; make test-page"]
fn tab_after_a_word_completes_it_and_elsewhere_indents() {
    let mut rig = Rig::open(WIDE);
    let end = rig.text().chars().count();
    rig.caret_to(end);
    rig.type_letters("select * from revenue_b");
    rig.key(Key::Escape, Mods::default());
    assert!(!rig.says("Tab or Enter puts it in"), "the popup is closed");
    rig.key(Key::Tab, Mods::default());
    assert!(
        rig.text().ends_with("select * from revenue_by_month"),
        "{:?}",
        rig.text()
    );
    rig.type_text("\n");
    rig.key(Key::Tab, Mods::default());
    assert!(
        rig.text().ends_with("revenue_by_month\n  "),
        "{:?}",
        rig.text()
    );
}

#[test]
#[ignore = "heavy: compiles the kit's interpreter and drives the page for seconds; make test-page"]
fn nothing_is_completed_in_a_string() {
    let mut rig = Rig::open(WIDE);
    let end = rig.text().chars().count();
    rig.caret_to(end);
    rig.type_letters("select 'ord");
    assert!(!rig.says("Tab or Enter puts it in"), "{:?}", rig.words());
}

#[test]
#[ignore = "heavy: compiles the kit's interpreter and drives the page for seconds; make test-page"]
fn what_is_selected_is_what_runs() {
    let mut rig = Rig::open(WIDE);
    let text = rig.text();
    let from = text.find("select * from revenue_by_month").unwrap();
    let from = text[..from].chars().count();
    rig.select(
        from,
        from + "select * from revenue_by_month".chars().count(),
    );
    rig.key(Key::Enter, cmd());
    let run = rig
        .asked
        .iter()
        .rev()
        .find(|call| call["method"] == "run")
        .expect("a run");
    assert_eq!(run["params"]["sql"], "select * from revenue_by_month");
}

#[test]
#[ignore = "heavy: compiles the kit's interpreter and drives the page for seconds; make test-page"]
fn a_postgres_table_off_the_path_is_completed_with_its_schema_and_runs() {
    let Ok(address) = std::env::var("SQLPEN_TEST_PG") else {
        eprintln!("SQLPEN_TEST_PG is not set: skipped");
        return;
    };
    let db = Db::Postgres(Box::new(
        crate::db::postgres::Postgres::connect(&address, false).unwrap(),
    ));
    let mut rig = Rig::open_on(WIDE, db);
    let end = rig.text().chars().count();
    rig.caret_to(end);
    rig.type_letters("select * from cust");
    assert!(rig.says("shop.customers"), "{:?}", rig.words());
    rig.key(Key::Tab, Mods::default());
    assert!(
        rig.text().ends_with("select * from shop.customers"),
        "{:?}",
        rig.text()
    );
    rig.type_letters(" c where c.");
    assert!(rig.says("email"), "{:?}", rig.words());
    rig.key(Key::Escape, Mods::default());
    rig.type_letters("country = 'TR' limit 5");
    rig.key(Key::Enter, cmd());
    assert!(
        rig.says("Results") && rig.says("email"),
        "{:?}",
        rig.words()
    );
    assert!(!rig.says("It did not run"), "{:?}", rig.words());
}

#[test]
#[ignore = "heavy: compiles the kit's interpreter and drives the page for seconds; make test-page"]
fn a_postgres_table_named_without_its_schema_says_where_it_is() {
    let Ok(address) = std::env::var("SQLPEN_TEST_PG") else {
        eprintln!("SQLPEN_TEST_PG is not set: skipped");
        return;
    };
    let db = Db::Postgres(Box::new(
        crate::db::postgres::Postgres::connect(&address, false).unwrap(),
    ));
    let mut rig = Rig::open_on(WIDE, db);
    let end = rig.text().chars().count();
    rig.caret_to(end);
    rig.type_text("select * from customers;");
    rig.command("run");
    assert!(rig.says("It did not run"), "{:?}", rig.words());
    assert!(
        rig.words()
            .iter()
            .any(|text| text.contains("write shop.customers")),
        "{:?}",
        rig.words()
    );
}

#[test]
#[ignore = "heavy: compiles the kit's interpreter and drives the page for seconds; make test-page"]
fn the_header_goes_across_with_the_rows_in_the_same_frame_and_stays_when_they_go_down() {
    let mut rig = Rig::open(WIDE);
    let end = rig.text().chars().count();
    rig.caret_to(end);
    let columns: Vec<String> = (1..=12).map(|n| format!("payload as p{n}")).collect();
    rig.type_text(&format!("select {} from events;", columns.join(", ")));
    rig.command("run");
    // Columns past the first view are there before anything scrolls.
    assert!(rig.says("p6"), "{:?}", rig.words());
    let head = |rig: &Rig| {
        rig.laid
            .bounds(Id::named("head:2"))
            .expect("the header of p2")
    };
    let cell = |rig: &Rig| rig.laid.bounds(Id::named("row:1")).expect("row 1");
    let (head_before, cell_before) = (head(&rig), cell(&rig));
    // The host scrolls across, on the page as it was last laid out: the page is not asked.
    rig.scrolls.ask(pencere_view::ScrollTo {
        id: Id::named("grid-across"),
        x: Some(200.0),
        y: None,
        animate: false,
    });
    rig.lay_out();
    assert_eq!(head(&rig).x, head_before.x - 200.0);
    assert_eq!(cell(&rig).x, cell_before.x - 200.0);
    // Down, the rows go and the header stays.
    rig.scrolls.ask(pencere_view::ScrollTo {
        id: Id::named("grid"),
        x: None,
        y: Some(240.0),
        animate: false,
    });
    rig.lay_out();
    assert_eq!(head(&rig).y, head_before.y);
    assert!(rig.laid.bounds(Id::named("row:11")).expect("row 11").y < cell_before.y + 24.0);
}

#[test]
#[ignore = "heavy: compiles the kit's interpreter and drives the page for seconds; make test-page"]
fn the_pointer_over_the_editor_is_a_place_to_type_after_the_divider_made_it_a_resize() {
    let mut rig = Rig::open(WIDE);
    let split = rig.laid.bounds(Id::named("split")).expect("the divider");
    let on_split = Point::new(split.x + split.w / 2.0, split.y + split.h / 2.0);
    rig.module.event(Event::Input(Input::Move(on_split)));
    rig.run();
    assert_eq!(rig.cursor, Some(pencere_view::Cursor::ResizeVertical));
    let editor = rig.laid.bounds(Id::named(SQL)).expect("the editor");
    rig.module.event(Event::Pointer {
        input: Input::Move(Point::new(editor.x + 40.0, editor.y + 20.0)),
        place: pencere_view::Place {
            editor: Id::named(SQL),
            at: 3,
        },
    });
    rig.run();
    assert_eq!(rig.cursor, Some(pencere_view::Cursor::Text));
}

#[test]
#[ignore = "heavy: compiles the kit's interpreter and drives the page for seconds; make test-page"]
fn the_header_of_each_column_is_as_wide_as_its_cells() {
    let mut rig = Rig::open(WIDE);
    rig.press("table:main.products", 2);
    assert!(rig.says("tags"), "{:?}", rig.words());
    let mut right = None;
    for column in 1..=6 {
        let head = rig
            .laid
            .bounds(Id::named(&format!("head:{column}")))
            .expect("a header");
        if let Some(right) = right {
            assert_eq!(
                head.x, right,
                "column {column} starts where the one before ends"
            );
        }
        right = Some(head.x + head.w);
    }
    // A cell stands under its header, as wide as it: the sixth column's chosen cell.
    rig.press_at_column("row:1", 1, 1);
    for _ in 0..5 {
        rig.key(Key::Right, Mods::default());
    }
    let head = rig
        .laid
        .bounds(Id::named("head:6"))
        .expect("the sixth header");
    let chosen = rig
        .laid
        .bounds(Id::named("chosen"))
        .expect("the chosen cell");
    assert_eq!((chosen.x, chosen.w), (head.x, head.w));
}

/// Pictures for the eye (`cargo test shots -- --ignored`, then look at target/shots/): the demo's
/// grid, a wide result scrolled across, the caret on its line, a selection, a fold, the completions, a plan, a mistake, an 80×24 pane.
#[test]
#[ignore = "heavy: draws pictures of the page for a person to look at"]
fn shots() {
    let mut rig = Rig::open(WIDE);
    rig.press("table:main.products", 2);
    rig.shot("grid");
    // Places in the editor are characters, `find` gives bytes, and the starter text has `·` and `⌘`.
    let place = |rig: &Rig, needle: &str| {
        let text = rig.text();
        text[..text.find(needle).unwrap()].chars().count()
    };
    rig.caret_to(place(&rig, "customers c on") + 4);
    rig.shot("caret");
    // A selection over three rows, and the first statement folded: the bands meet, the marker
    // sits on the text.
    rig.select(place(&rig, "count(*)"), place(&rig, "customer_id"));
    rig.shot("selection");
    rig.caret_to(0);
    rig.fold();
    rig.shot("folded");
    rig.fold();
    let end = rig.text().chars().count();
    rig.caret_to(end);
    rig.type_letters("select * from ord");
    rig.shot("completions");
    rig.key(Key::Escape, Mods::default());
    let at = rig.text().find("select c.country").unwrap() + 3;
    rig.caret_to(at);
    rig.command("explain");
    rig.shot("plan");
    // The mistake on a line in view: the wave under the word, the dot in the gutter.
    rig.caret_to(place(&rig, "\n\nselect c.country") + 1);
    rig.type_text("select nme from customers;");
    rig.command("run");
    rig.shot("mistake");
    // The kit's options of how an editor looks, others than the page's.
    let mut looks = Rig::open_with(
        WIDE,
        Db::Sqlite(Sqlite::demo(false).unwrap()),
        r#"line_height = 1.8, padding = 10, numbers = "relative",
           caret = { shape = "block", color = "accent" },
           colors = { current_line = { "accent", 0.08 }, current_number = "accent" },"#,
    );
    let at = {
        let text = looks.text();
        text[..text.find("customers c on").unwrap()].chars().count()
    };
    looks.caret_to(at);
    looks.shot("looks");
    let mut narrow = Rig::open(NARROW);
    let at = narrow
        .text()
        .find("select * from revenue_by_month")
        .unwrap()
        + 3;
    narrow.caret_to(at);
    narrow.command("run");
    narrow.shot("narrow");
}
