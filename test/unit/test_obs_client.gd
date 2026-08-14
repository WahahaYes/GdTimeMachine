extends GutTest

## Phase 0 auth gate (PLAN_obs_backend_v2.md §3.1) + client half of the
## plumbing proof (§3.2).
##
## The three vectors below were computed INDEPENDENTLY with python3
## hashlib/base64 — NOT by the function under test (the v1 vectors were
## self-suspected in the seed prompt; a fresh reference run reproduces them
## exactly). They are the hard regression lock: any auth change that shifts
## them fails CI immediately.
##
## Reference logic (one-liner):
##   base64(sha256(base64(sha256(password + salt)) + challenge))
##   ("password",  "salt", "challenge")  → zTM5ki6L2vVvBQiTG9ckH1Lh64AbnCf6XZ226UmnkIA=
##   ("p@ss w0rd", "s01t", "chal-1")     → OviXHTMUDxkuThqADhlITYdX+RovQ9rp+QknwnKk4MY=
##   ("", "", "")                        → XEB0z23rR/W2r5xf4+C70OQrlZb+iKxU1ca275h+DyA=

const REF_PASSWORD_1 := "password"
const REF_SALT_1 := "salt"
const REF_CHALLENGE_1 := "challenge"
const REF_VECTOR_1 := "zTM5ki6L2vVvBQiTG9ckH1Lh64AbnCf6XZ226UmnkIA="

const REF_PASSWORD_2 := "p@ss w0rd"
const REF_SALT_2 := "s01t"
const REF_CHALLENGE_2 := "chal-1"
const REF_VECTOR_2 := "OviXHTMUDxkuThqADhlITYdX+RovQ9rp+QknwnKk4MY="

const REF_VECTOR_EMPTY := "XEB0z23rR/W2r5xf4+C70OQrlZb+iKxU1ca275h+DyA="


func test_generate_auth_matches_python_reference() -> void:
	assert_eq(
		OBSClient._generate_auth(REF_PASSWORD_1, REF_SALT_1, REF_CHALLENGE_1),
		REF_VECTOR_1,
	)


func test_generate_auth_special_characters_matches_reference() -> void:
	assert_eq(
		OBSClient._generate_auth(REF_PASSWORD_2, REF_SALT_2, REF_CHALLENGE_2),
		REF_VECTOR_2,
	)


func test_generate_auth_empty_input_matches_reference() -> void:
	assert_eq(OBSClient._generate_auth("", "", ""), REF_VECTOR_EMPTY)


func test_connect_to_obs_stores_password() -> void:
	var client := OBSClient.new()
	client.connect_to_obs(OBSClient.DEFAULT_HOST, OBSClient.DEFAULT_PORT, "secret")
	assert_eq(client._password, "secret")


func test_connect_to_obs_rejects_out_of_range_port() -> void:
	var client := OBSClient.new()
	assert_eq(client.connect_to_obs(OBSClient.DEFAULT_HOST, 0, ""), ERR_INVALID_PARAMETER)
