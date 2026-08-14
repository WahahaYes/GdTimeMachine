extends GutTest

## Phase 0 plumbing proof (PLAN_obs_backend_v2.md §3.2): the OBS password the
## user sets in Project > Editor Settings must reach _password on the client.
## These tests prove the read half — _get_obs_settings()/typed readers resolve
## the password from the settings store, EditorSettings-first then
## ProjectSettings-fallback. The assign half (connect_to_obs → _password) lives
## in test_obs_client.gd. The single seam that joins them (the backend's
## start()/probe forwarding settings-password into connect_to_obs) lands with
## Phase 2.
##
## EditorSettings cannot exist in headless GUT — Engine.has_singleton(
## "EditorSettings") is FALSE in 4.7 even under --editor (the v1 Bug-7 root
## cause, see PROGRESS_obs_backend_v2.md §3.2) — so the EditorSettings-present
## branch is covered by injecting a fake store through _editor_settings, the
## same seam EditorSettingsConfigStore already uses.

const PASSWORD_KEY := "gd_time_machine/obs/password"
const TEST_PASSWORD := "phase0-plumbing-password"


## Fake EditorSettings store: get_setting() returns per-key values or null,
## exactly like the real singleton's missing-key behavior.
class FakeEditorSettings:
	extends RefCounted
	var _values := {}

	func set_v(key: String, value: Variant) -> void:
		_values[key] = value

	func get_setting(name: String) -> Variant:
		return _values.get(name, null)


func before_each() -> void:
	ProjectSettings.clear(PASSWORD_KEY)


func _read_password(backend: BackendOBS) -> String:
	return str(backend._get_obs_settings().get("password", ""))


func _make_backend() -> BackendOBS:
	# add_child_autofree returns an untyped value, so the caller must annotate.
	return add_child_autofree(BackendOBS.new())


func test_password_read_from_project_settings_fallback() -> void:
	# EditorSettings absent (headless; _editor_settings null) → readers must
	# fall through to ProjectSettings, not to the default.
	ProjectSettings.set_setting(PASSWORD_KEY, TEST_PASSWORD)
	assert_eq(_read_password(_make_backend()), TEST_PASSWORD)


func test_empty_password_default_when_unset() -> void:
	# Nothing set anywhere → empty password (server auth disabled case).
	assert_eq(_read_password(_make_backend()), "")


func test_editor_settings_shadow_project_settings() -> void:
	# EditorSettings present (fake injected) → its password wins even when
	# ProjectSettings holds a different value. This is the precedence that
	# produced the v1 4009 when the two stores disagreed.
	var fake := FakeEditorSettings.new()
	fake.set_v(PASSWORD_KEY, TEST_PASSWORD)
	ProjectSettings.set_setting(PASSWORD_KEY, "shadowed")
	var backend: BackendOBS = _make_backend()
	backend._editor_settings = fake
	assert_eq(_read_password(backend), TEST_PASSWORD)


func test_project_settings_reads_through_typed_reader() -> void:
	ProjectSettings.set_setting(PASSWORD_KEY, TEST_PASSWORD)
	assert_eq(_make_backend()._get_setting_string(PASSWORD_KEY, "default"), TEST_PASSWORD)


func test_port_reader_falls_back_to_default() -> void:
	assert_eq(_make_backend()._get_obs_settings().get("port", 0), OBSClient.DEFAULT_PORT)
