load("@bazel_skylib//lib:shell.bzl", "shell")
load(":oss_shim.bzl", "buck_genrule", "get_visibility")
load(":artifacts_require_repo.bzl", "built_artifacts_require_repo")

_ARTIFACTS_REQUIRE_REPO = built_artifacts_require_repo()

def maybe_wrap_runtime_deps_as_build_time_deps(
        name,
        target,
        visibility,
        path_in_output = None,
        dynamic_path_in_output = False):
    """
    If necessary (see "When..."), wraps `target` with a new target named
    `name`, in the current project.

    Returns `(False, target)` if unwrapped, or `(True, ':<name>')` otherwise.

    The build-time dependencies of the wrapper `:<name>` will include the
    run-time dependencies of `target`.

    Wrapping is commonly used when `image.layer` will run `target` as part
    of its build process, or when some target needs to be executable from
    inside an `image.layer`.

    IMPORTANT: The build artifact of `:<name>` is NOT cacheable, so if you
    include its contents in some other artifact, that artifact must ALSO
    become non-cacheable.

    ## Special situations

      - `path_in_output` sets the wrapper to execute a fixed file out of a
        directory that is output by an executable rule.

      - `dynamic_path_in_output` was made for `install_executable_trees`,
         where we need the wrapper to be able to execute multiple files from
         a directory that was output by an executable target, and the file
         paths are not known at runtime.

         DANGER: This DRASTICALLY changes the API of the wrapper target.
         When you execute a `dynamic_path_in_output=True` wrapper, its
         `$1` is interpreted as a path inside the output directory,
         under `path_in_output`. In other words, the wrapper runs:

             buck-out/gen/<target>/out/<path_in_output>/$1

         This means that when you use `dynamic_path_in_output=True`, you
         must separately handle the case when the target is returned
         unwrapped -- the wrapped & unwrapped targets work DIFFERENTLY.

    ## Why is wrapping needed?

    There are two reasons for wrapping.

      - The primary reason for this is that due to Buck limitations,
        `image.layer` cannot directly take on run-time dependencies (more on
        that below), so the wrapper makes ALL dependencies (run-time or
        build-time) look like build-time dependencies.

      - The second reason is to execute in-place (aka @mode/dev) binaries
        from inside an image -- in that case, the wrapper acts much like a
        symlink, although it ALSO has the effect of ensuring that the image
        gets rebuilt if any of the runtime dependencies of its contained
        executables change.  In many cases, this results in over-building in
        @mode/dev -- the more performant solution would be to have a tag on
        in-image executables signaling whether they are permitted to be used
        as part of the image build.  For most, the tag would say "no", and
        those would not need runtime dependency wrapping.  However, the
        extra complexity makes this idea "far future".

    Here is what would go wrong if we just passed `target` directly to
    `image.layer` to execute:

     - For concreteness' sake, let's say that `target` needs to be
       executed by the `image.layer` build script (as is the case for
       `generator` from `tarballs`).

     - `image.layer` will use $(query_targets_and_outputs) to find the
       output path for `target`.

     - Suppose that `target`'s source code CHANGED since the last time our
       layer was built.

     - Furthermore, suppose that the output of `target` is a thin wrapper,
       such as what happens with in-place Python executables in @mode/dev.
       Even though the FUNCTIONALITY of the Python executable has changed,
       the actual build output will remain the same.

     - At this point, the output path that's included in the bash command of
       the layer's genrule has NOT changed.  The file referred to by that
       output path has NOT changed.  Only its run-time dependencies (the
       in-place symlinks to the actual `.py` files) have changed.
       Therefore, as far as build-time dependencies of the layer are
       concerned, the layer does not need to re-build: the inputs of the
       layer genrule are bitwise the same as the inputs before any changes
       to `target`'s source code.

       In other words, although `target` itself WOULD get rebuilt due to
       source code changes, the layer that depends on that target WOULD NOT
       get rebuilt, because it does not consider the `.py` files inside the
       in-place Python link-tree to be build-time inputs.  Those are runtime
       dependencies.  Peruse the docs here for a Buck perspective:
           https://github.com/facebook/buck/blob/master/src/com/facebook/
           buck/core/rules/attr/HasRuntimeDeps.java

    We could avoid the wrapper if we could add `target` as a **runtime
    dependency** to the `image.layer` genrule.  However, Buck does not make
    this possible.  It is possible to add runtime dependencies on targets
    that are KNOWN to the `image.layer` macro at parse time, since one could
    then use `$(exe)` -- which says "rebuild me if the mentioned target's
    runtime dependencies have changed".  But because we want to support
    composition of layers via features, `$(exe)` does not help -- the layer
    has to discover its features' dependencies via a query.  Unfortunately,
    Buck's query facilities of today only allow making build-time
    dependencies (not runtime dependencies).  So supporting the right API
    would require a change in Buck.  Either of these would do:

      - Support adding query-determined runtime dependencies to
        genrules -- via a special-purpose macro, a macro modifier, or a rule
        attribute.

      - Support Bazel-style providers, which would let the layer
        implementation directly access the data collated by its features.
        Then, the layer could just issue $(exe) macros for all runtime-
        dependency targets.  NB: This would bring a build speed win, too.

    ## When should we NOT wrap?

    This build-time -> run-time dependency wrapper doesn't work inside
    @mode/opt containers, since those (deliberately) don't bind-mount the
    repo inside.  They are supposed to be self-contained and ready for
    production.

    However, in @mode/opt we don't care about the build-time / run-time
    dependency problem since C++ & Python build artifacts are
    self-contained, making the two dependency types identical.

    NB: This check here causes the target graphs to be subtly different
    between @mode/dev and @mode/opt.  I don't expect this to cause
    problems for CI, however, because this internal target shouldn't have
    any semantics for our test or build infrastructure.
    """
    if not _ARTIFACTS_REQUIRE_REPO:
        return False, target
    buck_genrule(
        name = name,
        out = "wrapper.sh",
        bash = '''
cat >> "$TMP/out" <<'EOF'
#!/bin/bash
{set_dynamic_path_in_output}\
exec $(exe {target_to_wrap}){quoted_path_in_output}{dynamic_path_in_output} "$@"
EOF
echo "# New output each build: \\$(date) $$ $PID $RANDOM $RANDOM" >> "$TMP/out"
chmod a+rx "$TMP/out"
mv "$TMP/out" "$OUT"
        '''.format(
            target_to_wrap = target,
            set_dynamic_path_in_output = "" if not dynamic_path_in_output else (
                "dynamic_path_in_output=$1\n" +
                "shift\n"
            ),
            quoted_path_in_output = "" if path_in_output == None else (
                "/" + shell.quote(path_in_output)
            ),
            dynamic_path_in_output = "" if not dynamic_path_in_output else '/"$dynamic_path_in_output"',
        ),
        # We deliberately generate a unique output on each rebuild.
        cacheable = False,
        # Whatever we wrap was executable, so the wrapper might as well be, too
        executable = True,
        visibility = get_visibility(visibility, name),
    )
    return True, ":" + name
