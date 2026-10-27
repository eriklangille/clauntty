use std::collections::HashMap;

/// A file's priority in a review
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Priority {
    Critical,
    Skim,
}

pub fn rank(files: &[(&str, Priority)]) -> HashMap<String, usize> {
    let mut out = HashMap::new();
    for (i, (path, p)) in files.iter().enumerate() {
        if *p == Priority::Critical {
            out.insert(format!("{path}:{}", i + 1), 0usize);
        }
    }
    out // 'static lifetimes aside
}
