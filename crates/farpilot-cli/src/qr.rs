use qrcode::{QrCode, render::unicode::Dense1x2};

pub fn render(value: &str) -> anyhow::Result<String> {
    let code = QrCode::new(value.as_bytes())?;
    Ok(code.render::<Dense1x2>().quiet_zone(true).build())
}
