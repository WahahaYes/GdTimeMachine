extends GutTest

## Manifest commit refs: validation and resolution against a scratch git repo
## (core/worktree.gd is_valid_ref / resolve_commit).

var _repo := ""


func _git(args: Array) -> String:
	var out: Array = []
	OS.execute("git", PackedStringArray(["-C", _repo] + args), out, true)
	return str(out[0]).strip_edges() if not out.is_empty() else ""


func before_all() -> void:
	_repo = OS.get_temp_dir().path_join("gdtm_refs_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_repo)
	_git(["init", "-q", "-b", "main"])
	_git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "a"])
	_git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "b"])
	_git(["branch", "scene-visual-pass", "HEAD~1"])
	_git(["tag", "v1", "HEAD~1"])


func after_all() -> void:
	OS.execute("rm", PackedStringArray(["-rf", _repo]))


func test_is_valid_ref_accepts_common_refs() -> void:
	for ref in ["HEAD", "abc1234", "scene-visual-pass", "v1.2.0", "HEAD~2", "origin/main"]:
		assert_true(GdTMWorktree.is_valid_ref(ref), ref)


func test_is_valid_ref_rejects_options_and_spaces() -> void:
	for ref in ["", "-n", "--all", "my branch", "a\tb"]:
		assert_false(GdTMWorktree.is_valid_ref(ref), "'%s'" % ref)


func test_resolve_commit_branch_tag_head_and_short_sha() -> void:
	var head := _git(["rev-parse", "HEAD"])
	var first := _git(["rev-parse", "HEAD~1"])
	assert_eq(GdTMWorktree.resolve_commit(_repo, "HEAD"), head)
	assert_eq(GdTMWorktree.resolve_commit(_repo, "main"), head)
	assert_eq(GdTMWorktree.resolve_commit(_repo, "scene-visual-pass"), first)
	assert_eq(GdTMWorktree.resolve_commit(_repo, "v1"), first)
	assert_eq(GdTMWorktree.resolve_commit(_repo, first.substr(0, 7)), first)
	assert_eq(head.length(), 40)


func test_resolve_commit_unknown_ref_is_empty() -> void:
	assert_eq(GdTMWorktree.resolve_commit(_repo, "no-such-branch"), "")
	assert_eq(GdTMWorktree.resolve_commit(_repo, "--all"), "")
