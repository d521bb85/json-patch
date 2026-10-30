use std::time::{Duration, Instant};

fn run(doc: &str, patch: &str) -> String {
    let mut value: serde_json::Value = serde_json::from_str(doc).unwrap();
    let patch: json_patch::Patch = serde_json::from_str(patch).unwrap();
    json_patch::patch(&mut value, &patch).unwrap();
    serde_json::to_string(&value).unwrap()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let dir = &args[1];
    let min = Duration::from_millis(args[2].parse().unwrap());
    for name in &args[3..] {
        let doc = std::fs::read_to_string(format!("{dir}/{name}.doc.json")).unwrap();
        let patch = std::fs::read_to_string(format!("{dir}/{name}.patch.json")).unwrap();
        let mut times = Vec::new();
        let mut result = String::new();
        let started = Instant::now();
        while times.len() < 5 || started.elapsed() < min {
            let start = Instant::now();
            result = run(&doc, &patch);
            times.push(start.elapsed().as_nanos() as u64);
            std::hint::black_box(&result);
        }
        times.sort();
        std::fs::write(format!("{dir}/out/rust.{name}.json"), &result).unwrap();
        println!("{} {}", name, times[times.len() / 2]);
    }
}
