use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=PGL_VALIDATE_PG_CONFIG");
    println!("cargo:rerun-if-env-changed=PGRX_PG_CONFIG_PATH");
    println!("cargo:rerun-if-env-changed=PG_CONFIG");

    if let Some(major) = active_pg_major() {
        println!("cargo:rerun-if-env-changed=PG{major}_PG_CONFIG");
    }

    let pg_config = find_pg_config()
        .unwrap_or_else(|| panic!("could not find pg_config for active pgl_validate build"));
    let libdir = pg_config_output(&pg_config, "--libdir");

    println!("cargo:rustc-link-search=native={libdir}");
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let target_env = env::var("CARGO_CFG_TARGET_ENV").unwrap_or_default();
    if target_os == "windows" && target_env == "msvc" {
        println!("cargo:rustc-link-lib=dylib=libpq");
    } else {
        println!("cargo:rustc-link-lib=pq");
    }
}

fn active_pg_major() -> Option<&'static str> {
    [
        ("18", "CARGO_FEATURE_PG18"),
        ("17", "CARGO_FEATURE_PG17"),
        ("16", "CARGO_FEATURE_PG16"),
        ("15", "CARGO_FEATURE_PG15"),
    ]
    .into_iter()
    .find_map(|(major, feature)| env::var_os(feature).map(|_| major))
}

fn find_pg_config() -> Option<PathBuf> {
    for env_name in ["PGL_VALIDATE_PG_CONFIG", "PGRX_PG_CONFIG_PATH", "PG_CONFIG"] {
        if let Some(path) = env::var_os(env_name)
            .map(PathBuf::from)
            .filter(|p| p.exists())
        {
            return Some(path);
        }
    }

    if let Some(major) = active_pg_major() {
        let env_name = format!("PG{major}_PG_CONFIG");
        if let Some(path) = env::var_os(&env_name)
            .map(PathBuf::from)
            .filter(|p| p.exists())
        {
            return Some(path);
        }

        if let Some(path) = pg_config_from_pgrx_config(major) {
            return Some(path);
        }
    }

    let path = PathBuf::from("pg_config");
    command_output(&path, "--version").map(|_| path)
}

fn pg_config_from_pgrx_config(major: &str) -> Option<PathBuf> {
    let home = env::var_os("USERPROFILE").or_else(|| env::var_os("HOME"))?;
    let config_path = PathBuf::from(home).join(".pgrx").join("config.toml");
    println!("cargo:rerun-if-changed={}", config_path.display());

    let config = std::fs::read_to_string(config_path).ok()?;
    let prefix = format!("pg{major}");
    for line in config.lines() {
        let trimmed = line.trim();
        let Some((key, value)) = trimmed.split_once('=') else {
            continue;
        };
        if key.trim() != prefix {
            continue;
        }
        let path = value.trim().trim_matches('\'').trim_matches('"');
        let path = PathBuf::from(path);
        if path.exists() {
            return Some(path);
        }
    }

    None
}

fn pg_config_output(pg_config: &PathBuf, arg: &str) -> String {
    command_output(pg_config, arg)
        .unwrap_or_else(|| panic!("{} {arg} failed", pg_config.display()))
        .trim()
        .to_string()
}

fn command_output(program: &PathBuf, arg: &str) -> Option<String> {
    let output = Command::new(program).arg(arg).output().ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8(output.stdout).ok()
}
