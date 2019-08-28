# Implementation detail for `image_layer.bzl`, see its docs.
load("@bazel_skylib//lib:shell.bzl", "shell")
load("@bazel_skylib//lib:types.bzl", "types")
load("//fs_image/buck:image_feature.bzl", "DO_NOT_DEPEND_ON_FEATURES_SUFFIX")
load(":artifacts_require_repo.bzl", "built_artifacts_require_repo")

def _build_opts(
        # The name of the btrfs subvolume to create.
        subvol_name = "volume",
        # Path to a binary target, with this CLI signature:
        #   yum_from_repo_snapshot --install-root PATH -- SOME YUM ARGS
        # Mutually exclusive with build_appliance: either
        # yum_from_repo_snapshot or build_appliance is required
        # if any dependent `image_feature` specifies `rpms`.
        yum_from_repo_snapshot = None,
        # Path to a target outputting a btrfs send-stream of a build appliance:
        # a self-contained file tree with /yum-from-snapshot and other tools
        # like btrfs, yum, tar, ln used for image builds along with all
        # their dependencies (but /usr/local/fbcode).  Mutually exclusive
        # with yum_from_repo_snapshot: either build_appliance or
        # yum_from_repo_snapshot is required if any dependent
        # `image_feature` specifies `rpms`.
        build_appliance = None):
    return struct(
        subvol_name = subvol_name,
        yum_from_repo_snapshot = yum_from_repo_snapshot,
        build_appliance = build_appliance,
    )

def _query_set(target_paths):
    'Returns `set("//foo:target1" "//bar:target2")` for use in Buck queries.'

    if not target_paths:
        return "set()"

    # This does not currently escape double-quotes since Buck docs say they
    # cannot occur: https://buck.build/concept/build_target.html
    return 'set("' + '" "'.join(target_paths) + '")'

def compile_image_features(
        current_target,
        parent_layer,
        features,
        build_opts):
    if features == None:
        features = []
    build_opts = _build_opts(**(
        build_opts._asdict() if build_opts else {}
    ))
    feature_targets = []
    direct_deps = []
    inline_feature_dicts = []
    for f in features:
        if types.is_string(f):
            feature_targets.append(f + DO_NOT_DEPEND_ON_FEATURES_SUFFIX)
        else:
            direct_deps.extend(f.deps)
            inline_feature_dicts.append(f.items._asdict())
            inline_feature_dicts[-1]["target"] = current_target

    return '''
        {maybe_yum_from_repo_snapshot_dep}
        # Take note of `targets_and_outputs` below -- this enables the
        # compiler to map the `__BUCK_TARGET`s in the outputs of
        # `image_feature` to those targets' outputs.
        #
        # `exe` vs `location` is explained in `image_package.py`.
        $(exe //fs_image:compiler) {maybe_artifacts_require_repo} \
          --subvolumes-dir "$subvolumes_dir" \
          --subvolume-rel-path \
            "$subvolume_wrapper_dir/"{subvol_name_quoted} \
          --parent-layer-json {parent_layer_json_quoted} \
          {maybe_quoted_build_appliance_args} \
          {maybe_quoted_yum_from_repo_snapshot_args} \
          --child-layer-target {current_target_quoted} \
          {quoted_child_feature_json_args} \
          --child-dependencies {feature_deps_query_macro} \
              > "$layer_json"
    '''.format(
        subvol_name_quoted = shell.quote(build_opts.subvol_name),
        parent_layer_json_quoted = "$(location {})/layer.json".format(
            parent_layer,
        ) if parent_layer else "''",
        current_target_quoted = shell.quote(current_target),
        quoted_child_feature_json_args = " ".join([
            "--child-feature-json $(location {})".format(t)
            for t in feature_targets
        ] + (
            ["--child-feature-json <(echo {})".format(shell.quote(struct(
                target = current_target,
                features = inline_feature_dicts,
            ).to_json()))] if inline_feature_dicts else []
        )),
        # We will ask Buck to ensure that the outputs of the direct
        # dependencies of our `image_feature`s are available on local disk.
        #
        # See `Implementation notes: Dependency resolution` in `__doc__` --
        # note that we need no special logic to exclude parent-layer
        # features, since this query does not traverse them anyhow.
        #
        # We have two layers of quoting here.  The outer '' groups the query
        # into a single argument for `query_targets_and_outputs`.  Then,
        # `_query_set` double-quotes each target name to allow the use of
        # special characters like `=` in target names.
        feature_deps_query_macro = """$(query_targets_and_outputs '
            {direct_deps_set} union
            deps(attrfilter(type, image_feature, deps({feature_set})), 1)
        ')""".format(
            # For inline `image.feature`s, we already know the direct deps.
            direct_deps_set = _query_set(direct_deps),
            # We will query the direct deps of the features that are targets.
            feature_set = _query_set(feature_targets),
        ),
        maybe_artifacts_require_repo = (
            "--artifacts-may-require-repo" if
            # Future: Consider **only** emitting this flag if the image is
            # actually contains executables (via `install_executable`).
            # NB: This may not actually be 100% doable at macro parse time,
            # since `install_executable_tree` does not know if it is
            # installing an executable file or a data file until build-time.
            # That said, the parse-time test would already narrow the scope
            # when the repo is mounted, and one could potentially extend the
            # compiler to further modulate this flag upon checking whether
            # any executables were in fact installed.
            built_artifacts_require_repo() else ""
        ),
        maybe_quoted_build_appliance_args = (
            "--build-appliance-json $(location {})/layer.json".format(
                build_opts.build_appliance,
            ) if build_opts.build_appliance else ""
        ),
        maybe_quoted_yum_from_repo_snapshot_args = (
            # In terms of **dependency** structure, we want this to be `exe`
            # (see `image_package.py` for why).  However the string output
            # of the `exe` macro may actually be a shell snippet, which
            # would break here.  To work around this, we add a no-op $(exe)
            # dependency via `maybe_yum_from_repo_snapshot_dep`.
            "--yum-from-repo-snapshot $(location {})".format(
                build_opts.yum_from_repo_snapshot,
            ) if build_opts.yum_from_repo_snapshot else ""
        ),
        maybe_yum_from_repo_snapshot_dep = (
            # Building the layer has a runtime depepndency on the yum
            # target.  We don't need this for `build_appliance` because any
            # @mode/dev executables inside a layer should already have been
            # wrapped via `wrap_runtime_deps`.
            "echo $(exe {}) > /dev/null".format(
                build_opts.yum_from_repo_snapshot,
            ) if build_opts.yum_from_repo_snapshot else ""
        ),
    )