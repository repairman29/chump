use broken_rust_app::add;

#[test]
fn add_two_and_two() {
    assert_eq!(add(2, 2), 5, "intentionally wrong expected value for baseline runs");
}
