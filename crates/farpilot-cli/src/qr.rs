pub fn render(value: &str) -> anyhow::Result<String> {
    let code = qrcode::QrCode::new(value.as_bytes())?;
    Ok(code
        .render::<qrcode::render::unicode::Dense1x2>()
        .quiet_zone(true)
        .build())
}
