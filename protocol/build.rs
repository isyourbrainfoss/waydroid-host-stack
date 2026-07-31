fn main() -> Result<(), Box<dyn std::error::Error>> {
    let protos = ["proto/waydroid_bt/v1/messages.proto"];
    prost_build::Config::new()
        .bytes(["."])
        .compile_protos(&protos, &["proto"])?;
    for p in &protos {
        println!("cargo:rerun-if-changed={p}");
    }
    Ok(())
}
