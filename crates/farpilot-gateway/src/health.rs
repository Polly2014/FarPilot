use axum::Json;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde::Serialize;

#[derive(Serialize)]
struct HealthBody {
    status: &'static str,
}

pub async fn live() -> Json<impl Serialize> {
    Json(HealthBody { status: "ok" })
}

pub fn readiness(is_ready: bool) -> Response {
    if is_ready {
        (StatusCode::OK, Json(HealthBody { status: "ok" })).into_response()
    } else {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(HealthBody {
                status: "unavailable",
            }),
        )
            .into_response()
    }
}
