//! The Rust names of an instance match api/instance-names.json; the Swift
//! app checks the same file.

use localcron_core::instance::Instance;
use serde_json::Value;

#[test]
fn names_match_the_shared_file() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../api/instance-names.json");
    let all: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    for (_, want) in all.as_object().unwrap() {
        let i = Instance::new(want["suffix"].as_str().unwrap()).unwrap();
        let got = serde_json::json!({
            "suffix": i.suffix(), "app_name": i.app_name(), "bundle_id": i.bundle_id(), "daemon_label": i.daemon_label(),
            "daemon_program": i.daemon_program(), "cli": i.cli(), "note": i.note(),
            "data_folder": i.data_folder(), "logs_folder": i.logs_folder(),
        });
        assert_eq!(&got, want);
    }
}
