//! Pictures of the page, for the eye: what the kit lays out and lists to draw, drawn into a PNG in
//! the system's fonts (Menlo for the terminal's face, SF for the system's) and a dark theme like a
//! terminal's. Not bateri's drawing — no shaping, no shadows, the system font's one weight — but
//! the same boxes, words, colours, pictures and editors where the kit puts them, which is what an
//! eye checks: what is aligned, what overlaps, what is cut.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use fontdue::{Font as Face, FontSettings};
use pencere_sandbox::draw_figure;
use pencere_view::{
    Color, DrawList, Family, Font, Measure, Metrics, Paint, Rect, Role, Size, Source,
};
use resvg::tiny_skia::{self, FillRule, Paint as Ink, PathBuilder, Pixmap, Stroke, Transform};

/// The faces: the terminal's (regular, bold, italic) and the system's.
pub struct Fonts {
    terminal: [Face; 3],
    system: Face,
    advances: HashMap<(u8, char, u32), f32>,
    /// Where the page's pictures are (`assets/…` of the bundle is under it).
    files: PathBuf,
}

fn face(path: &str, index: u32) -> Face {
    let bytes = std::fs::read(path).unwrap_or_else(|why| panic!("{path}: {why}"));
    Face::from_bytes(
        bytes,
        FontSettings {
            collection_index: index,
            scale: 40.0,
            ..FontSettings::default()
        },
    )
    .unwrap_or_else(|why| panic!("{path}: {why}"))
}

impl Fonts {
    pub fn new(files: PathBuf) -> Self {
        Self {
            files,
            terminal: [
                face("/System/Library/Fonts/Menlo.ttc", 0),
                face("/System/Library/Fonts/Menlo.ttc", 1),
                face("/System/Library/Fonts/Menlo.ttc", 2),
            ],
            system: face("/System/Library/Fonts/SFNS.ttf", 0),
            advances: HashMap::new(),
        }
    }

    fn pick(&self, font: &Font) -> (u8, &Face) {
        match font.family {
            Family::Terminal if font.weight >= 600 => (1, &self.terminal[1]),
            Family::Terminal if font.italic => (2, &self.terminal[2]),
            Family::Terminal => (0, &self.terminal[0]),
            _ => (3, &self.system),
        }
    }

    fn advance(&mut self, font: &Font, c: char) -> f32 {
        let (which, face) = self.pick(font);
        let key = (which, c, font.size.to_bits());
        if let Some(advance) = self.advances.get(&key) {
            return *advance;
        }
        let advance = face.metrics(c, font.size).advance_width;
        self.advances.insert(key, advance);
        advance
    }

    fn line(&self, font: &Font) -> (f32, f32) {
        let (_, face) = self.pick(font);
        face.horizontal_line_metrics(font.size)
            .map_or((font.size * 0.8, font.size * 1.25), |line| {
                (line.ascent, line.ascent - line.descent + line.line_gap)
            })
    }
}

impl Measure for Fonts {
    fn measure(&mut self, font: &Font, text: &str) -> Metrics {
        let width = text.chars().map(|c| self.advance(font, c)).sum();
        Metrics {
            width,
            height: self.line(font).1,
        }
    }

    /// The size of a picture of the page: an SVG's own, as the host's decoder says it.
    fn image(&mut self, src: &str) -> Option<Size> {
        let svg = std::fs::read(self.files.join(src)).ok()?;
        let tree = resvg::usvg::Tree::from_data(&svg, &resvg::usvg::Options::default()).ok()?;
        Some(Size::new(tree.size().width(), tree.size().height()))
    }
}

/// A dark theme like a terminal's (the colours of a page's `context` in the protocol's example).
fn theme(role: Role) -> [f32; 4] {
    fn hex(rgb: u32) -> [f32; 4] {
        [
            ((rgb >> 16) & 0xff) as f32 / 255.0,
            ((rgb >> 8) & 0xff) as f32 / 255.0,
            (rgb & 0xff) as f32 / 255.0,
            1.0,
        ]
    }
    fn mix(a: [f32; 4], b: [f32; 4], t: f32) -> [f32; 4] {
        [
            a[0] + (b[0] - a[0]) * t,
            a[1] + (b[1] - a[1]) * t,
            a[2] + (b[2] - a[2]) * t,
            1.0,
        ]
    }
    const ANSI: [u32; 16] = [
        0x484f58, 0xff7b72, 0x3fb950, 0xd29922, 0x58a6ff, 0xbc8cff, 0x39c5cf, 0xb1bac4, 0x6e7681,
        0xffa198, 0x56d364, 0xe3b341, 0x79c0ff, 0xd2a8ff, 0x56d4dd, 0xf0f6fc,
    ];
    let background = hex(0x0d1117);
    let foreground = hex(0xc9d1d9);
    let dim = hex(0x8b949e);
    match role {
        Role::Background => background,
        Role::Foreground => foreground,
        Role::Dim => dim,
        Role::Accent | Role::Info => hex(0x58a6ff),
        Role::Cursor => hex(0x79c0ff),
        Role::Success => hex(0x3fb950),
        Role::Error => hex(0xf85149),
        Role::Warning => hex(0xd29922),
        Role::Border => hex(0x30363d),
        Role::Selection => hex(0x1f3d5c),
        Role::Raised(n) => mix(background, foreground, 0.04 * f32::from(n.min(8))),
        Role::Quiet => mix(dim, background, 1.0 / 3.0),
        Role::Shadow => [0.0, 0.0, 0.0, 1.0],
        other => {
            let index = Role::ANSI
                .iter()
                .position(|ansi| *ansi == other)
                .unwrap_or(7);
            hex(ANSI[index])
        }
    }
}

fn resolve(color: Color) -> [f32; 4] {
    color.resolve(|source| match source {
        Source::Role(role) => theme(role),
        Source::Rgba { light, dark } => {
            let value = dark.unwrap_or(light);
            [
                f32::from(value.r) / 255.0,
                f32::from(value.g) / 255.0,
                f32::from(value.b) / 255.0,
                f32::from(value.a) / 255.0,
            ]
        }
    })
}

fn ink(color: Color) -> Ink<'static> {
    let [r, g, b, a] = resolve(color);
    let mut paint = Ink::default();
    paint.set_color_rgba8(
        (r * 255.0) as u8,
        (g * 255.0) as u8,
        (b * 255.0) as u8,
        (a * 255.0) as u8,
    );
    paint.anti_alias = true;
    paint
}

fn intersect(a: Rect, b: Rect) -> Option<Rect> {
    let x = a.x.max(b.x);
    let y = a.y.max(b.y);
    let right = (a.x + a.w).min(b.x + b.w);
    let bottom = (a.y + a.h).min(b.y + b.h);
    (right > x && bottom > y).then(|| Rect::new(x, y, right - x, bottom - y))
}

fn rounded(rect: Rect, radii: [f32; 4]) -> Option<tiny_skia::Path> {
    let mut path = PathBuilder::new();
    let limit = rect.w.min(rect.h) / 2.0;
    let [tl, tr, br, bl] = radii.map(|r| r.clamp(0.0, limit));
    let (x, y, right, bottom) = (rect.x, rect.y, rect.x + rect.w, rect.y + rect.h);
    path.move_to(x + tl, y);
    path.line_to(right - tr, y);
    path.quad_to(right, y, right, y + tr);
    path.line_to(right, bottom - br);
    path.quad_to(right, bottom, right - br, bottom);
    path.line_to(x + bl, bottom);
    path.quad_to(x, bottom, x, bottom - bl);
    path.line_to(x, y + tl);
    path.quad_to(x, y, x + tl, y);
    path.close();
    path.finish()
}

/// Puts `coverage` (one byte a pixel, `width` wide) on `pixmap` at `x`, `y` in `color`, within `clip`.
#[allow(clippy::too_many_arguments)]
fn blit(
    pixmap: &mut Pixmap,
    coverage: &[u8],
    width: usize,
    x: i32,
    y: i32,
    color: [f32; 4],
    clip: Rect,
) {
    let (w, h) = (pixmap.width() as i32, pixmap.height() as i32);
    let pixels = pixmap.data_mut();
    for (row, line) in coverage.chunks(width.max(1)).enumerate() {
        let py = y + row as i32;
        if py < 0 || py >= h || (py as f32) < clip.y || (py as f32) >= clip.y + clip.h {
            continue;
        }
        for (column, value) in line.iter().enumerate() {
            let px = x + column as i32;
            if px < 0
                || px >= w
                || (px as f32) < clip.x
                || (px as f32) >= clip.x + clip.w
                || *value == 0
            {
                continue;
            }
            let alpha = f32::from(*value) / 255.0 * color[3];
            let at = ((py * w + px) * 4) as usize;
            for channel in 0..3 {
                let under = f32::from(pixels[at + channel]);
                pixels[at + channel] = (under + (color[channel] * 255.0 - under) * alpha) as u8;
            }
            pixels[at + 3] = 255;
        }
    }
}

/// Draws `list` (already with its editors' drawing in it) into a PNG of `width` × `height` pixels at
/// `path`; `assets` is where the page's pictures are (`assets/…` of the bundle).
pub fn png(
    list: &DrawList,
    fonts: &mut Fonts,
    width: u32,
    height: u32,
    assets: &Path,
    path: &Path,
) {
    let mut pixmap = Pixmap::new(width, height).expect("a picture");
    let [r, g, b, _] = theme(Role::Background);
    pixmap.fill(tiny_skia::Color::from_rgba(r, g, b, 1.0).expect("a colour"));
    let mut glyphs: HashMap<(u8, char, u32), (fontdue::Metrics, Vec<u8>)> = HashMap::new();
    for item in &list.items {
        match item {
            Paint::Quad(quad) => {
                let Some(shown) = intersect(quad.rect, quad.clip) else {
                    continue;
                };
                let fill = quad
                    .fill
                    .or(quad.gradient.map(|gradient| gradient.middle()));
                if let (Some(fill), Some(path)) = (fill, rounded(shown, quad.radii)) {
                    pixmap.fill_path(
                        &path,
                        &ink(fill),
                        FillRule::Winding,
                        Transform::identity(),
                        None,
                    );
                }
                if let Some(border) = quad.border {
                    let half = border.width / 2.0;
                    let inner = Rect::new(
                        quad.rect.x + half,
                        quad.rect.y + half,
                        quad.rect.w - border.width,
                        quad.rect.h - border.width,
                    );
                    if let (Some(path), Some(_)) =
                        (rounded(inner, quad.radii), intersect(inner, quad.clip))
                    {
                        let stroke = Stroke {
                            width: border.width,
                            ..Stroke::default()
                        };
                        pixmap.stroke_path(
                            &path,
                            &ink(border.color),
                            &stroke,
                            Transform::identity(),
                            None,
                        );
                    }
                }
            }
            Paint::Text(run) => {
                let color = resolve(run.color);
                let (ascent, _) = fonts.line(&run.font);
                let baseline = run.origin.y + ascent;
                let mut pen = run.origin.x;
                let (which, _) = fonts.pick(&run.font);
                for c in run.text.chars() {
                    let key = (which, c, run.font.size.to_bits());
                    let (metrics, coverage) = glyphs
                        .entry(key)
                        .or_insert_with(|| fonts.pick(&run.font).1.rasterize(c, run.font.size));
                    let x = (pen + metrics.xmin as f32).round() as i32;
                    let y =
                        (baseline - (metrics.height as f32 + metrics.ymin as f32)).round() as i32;
                    blit(&mut pixmap, coverage, metrics.width, x, y, color, run.clip);
                    pen += metrics.advance_width;
                }
                if run.underline || run.strike {
                    let y = if run.underline {
                        baseline + 2.0
                    } else {
                        baseline - ascent * 0.3
                    };
                    let line = vec![255u8; (pen - run.origin.x).max(0.0) as usize];
                    blit(
                        &mut pixmap,
                        &line,
                        line.len(),
                        run.origin.x as i32,
                        y as i32,
                        color,
                        run.clip,
                    );
                }
            }
            Paint::Figure(figure) => {
                if let Some(bitmap) = draw_figure(figure, resolve) {
                    let Some(source) = tiny_skia::PixmapRef::from_bytes(
                        bitmap.pixels(),
                        bitmap.width,
                        bitmap.height,
                    ) else {
                        continue;
                    };
                    pixmap.draw_pixmap(
                        figure.rect.x as i32,
                        figure.rect.y as i32,
                        source,
                        &tiny_skia::PixmapPaint::default(),
                        Transform::identity(),
                        None,
                    );
                }
            }
            Paint::Image(picture) => {
                let Ok(svg) = std::fs::read(assets.join(&picture.src)) else {
                    continue;
                };
                let Ok(tree) = resvg::usvg::Tree::from_data(&svg, &resvg::usvg::Options::default())
                else {
                    continue;
                };
                let (w, h) = (picture.rect.w.ceil() as u32, picture.rect.h.ceil() as u32);
                let Some(mut drawn) = Pixmap::new(w.max(1), h.max(1)) else {
                    continue;
                };
                let size = tree.size();
                resvg::render(
                    &tree,
                    Transform::from_scale(w as f32 / size.width(), h as f32 / size.height()),
                    &mut drawn.as_mut(),
                );
                let tint = picture.tint.map(resolve);
                let coverage: Vec<u8> = drawn.data().chunks(4).map(|pixel| pixel[3]).collect();
                let color = tint.unwrap_or([0.8, 0.8, 0.8, 1.0]);
                let color = [color[0], color[1], color[2], color[3] * picture.opacity];
                blit(
                    &mut pixmap,
                    &coverage,
                    w as usize,
                    picture.rect.x as i32,
                    picture.rect.y as i32,
                    color,
                    picture.clip,
                );
            }
            Paint::Editor(_) => {}
        }
    }
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    pixmap.save_png(path).expect("the picture saved");
}
