// Carries the page (src/view/) and the pictures (src/assets/) into the program: `pencere::app!()`
// is them. Under `pencere dev` the program reads them from the project instead, and shows the view
// again when one of them changes.
fn main() {
    if let Err(why) = pencere::build::app() {
        panic!("the files of src/view/ and src/assets/: {why}");
    }
}
