"""
We want to be able to use packages of files, fetched from an external data
store, for in-repo builds. Conceptually, this is pretty simple:
  - The repo stores an address and a cryptographic hash of the package.
  - There's a build target that fetches the package, checks the hash, and
    presents the package contents as an `image.layer`.

The above process is repo-hermetic (unless the package is unavailable), and
lets repo builds use pre-built artifacts. Such artifacts bring two benefits:
  - Speed: we can explicitly cache large, infrequently changed artifacts.
  - Controlled API churn: I may want to use a "stable" version of my
    dependency, rather than whatever I might build off trunk.

The details of "how to fetch a package" will vary depending on the package
store. This is abstracted by `_PackageFetcherInfo` below.

The glue code in this file specifies a uniform way of exposing package
stores as Buck targets. Its opinions are, roughly:

  - The data store has many versions of the package, each one immutable.
    New versions keep getting added.  However, a repo checkout may only
    access some fixed versions of a package via "tags".  Each (package, tag)
    pair results in a completely repo-deterministic `image.layer`.

  - In the repo, a (package, tag) pair is an `image.layer` target in a
    centralized repo location.

  - The layer's mount info has a correctly populated `runtime_source`, so if
    another layer mounts it at build-time, then this mount can be replicated
    at runtime.

  - Two representations are provided for the in-repo package database:
    performant `.bzl` and merge-conflict-free "json dir".

Most users should use the performant `.bzl` database format, as follows:

    # pkg/pkg.bzl
    def _fetched_layer(name, tag = "stable"):
        return "//pkg/db:" + name + "/" + tag + "-USE-pkg.fetched_layer"
    pkg = struct(fetched_layer = _fetched_layer)

    # pkg/db/db.bzl
    package_db = {"package": {"tag": {"address": ..., "hash", ...}}

    # pkg/db/TARGETS
    load(":db.bzl", "package_db")
    fetched_package_layers_from_db(
        fetcher = {
            "extra_deps": ["`image.source` "generator" to download package"],
            "fetch_package": "writes `tarball`/`install_files` JSON to stdout",
            "print_mount_config": "adds package address to `runtime_source`",
        },
        package_db = package_db,
        target_suffix = "-USE-pkg.fetched_layer",
    )

Now you can refer to a stable version of a package, represented as an
`image.layer`, via `pkg.fetched_layer("name")`.

## When to use the "json dir" DB format?

With a `.bzl` database, the expected use-case is that there is a single,
centralized automation that synchronizes the in-repo package-tag map with
the external source of truth for packages and their tags.

If you expect some packages to be updated by other, independent automations,
then it is no longer a good idea to store all packages in a single file --
merge conflicts will cause all these automations to break.

The "json dir" DB format is free of merge conflicts, so long as
each package-tag pair is only update by one automation.

To get the best of both worlds, use this pattern:
  - All "normal" packages are stored in a `.bzl` database and have one
    automation to update all packages in bulk.
  - Special packages (fewer in quantity) live in a "json dir" database.
"""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//lib:shell.bzl", "shell")
load("@bazel_skylib//lib:types.bzl", "types")
load("//fs_image/buck:oss_shim.bzl", "buck_genrule", "get_visibility")
load(":image_feature.bzl", "private_do_not_use_feature_json_genrule")
load(":image_layer.bzl", "image_layer")
load(":target_tagger.bzl", "normalize_target")

_PackageFetcherInfo = provider(fields = [
    # This executable target prints a feature JSON responsible for
    # configuring the entire layer to represent the fetched package,
    # including file data, owner, mode, etc.
    #
    # See each fetcher's in-source docblock for the details of its contract.
    "fetch_package",
    # The executable target `fetch_package` may reference other targets
    # (usually tagged via __BUCK_TARGET or similar) in their features.  Any
    # such target must ALSO be manually added to `extra_deps` so that
    # `image_layer.bzl` can resolve those dependencies correctly.
    "extra_deps",
    # An executable target that defines `runtime_source` and
    # `default_mountpoint` for the `mount_config` of the package layer.
    "print_mount_config",
])

# Read the doc-block for the purpose and high-level usage.
def fetched_package_layers_from_bzl_db(
        # `{"package": {"tag": <how to fetch>}}` -- you would normally get
        # this by `load`ing a autogenerated `db.bzl` exporting just 1 dict.
        package_db,
        # Dict of `_PackageFetcherInfo` kwargs
        fetcher,
        # Layer targets will have the form `<package>/<tag><suffix>`.
        # See `def _fetched_layer` in the docblock for the intended usage.
        target_suffix,
        visibility = None):
    for package, tags in package_db.items():
        for tag, how_to_fetch in tags.items():
            _fetched_package_layer(
                name = package + "/" + tag + target_suffix,
                package = package,
                how_to_fetch = how_to_fetch,
                fetcher = fetcher,
                visibility = visibility,
            )

# Read the doc-block for the purpose and high-level usage.
def fetched_package_layers_from_json_dir_db(
        # Path to a database directory inside the current project (i.e.
        # relative to the parent of your TARGETS file).
        package_db_dir,
        # Dict of `_PackageFetcherInfo` kwargs
        fetcher,
        # Layer targets will have the form `<package>/<tag><suffix>`.
        # See `def _fetched_layer` in the docblock for the intended usage.
        target_suffix,
        visibility = None):
    # Normalizing lets us treat `package_dir_db` as a prefix.  It also
    # avoids triggering a bug in Buck, causing it to silently abort when a
    # glob pattern starts with `./`.
    package_db_prefix = paths.normalize(package_db_dir) + "/"
    suffix = ".json"
    for p in native.glob([package_db_prefix + "*/*" + suffix]):
        if not p.startswith(package_db_prefix) or not p.endswith(suffix):
            fail("Bug: {} was not {}*/*{}".format(p, package_db_prefix, suffix))
        package, tag = p[len(package_db_prefix):-len(suffix)].split("/")
        export_file(name = p)
        _fetched_package_layer(
            name = package + "/" + tag + target_suffix,
            package = package,
            how_to_fetch = ":" + p,
            fetcher = fetcher,
            visibility = visibility,
        )

# Instead of using this stand-alone, use `fetched_package_layers_from_db` to
# define packages uniformly in one project.  This ensures each package is
# only fetched once.
def _fetched_package_layer(
        name,
        package,
        # One of two options:
        #   - A JSONable dict describing how to fetch the package instance.
        #   - A string path to a target whose output has a comment on the
        #     first line, and JSON on subsequent lines.
        how_to_fetch,
        # Dict of `_PackageFetcherInfo` fields, documented above.
        fetcher,
        visibility = None):
    fetcher = _PackageFetcherInfo(**fetcher)
    visibility = get_visibility(visibility, name)
    if types.is_dict(how_to_fetch):
        print_how_to_fetch_json = "echo " + shell.quote(
            struct(**how_to_fetch).to_json(),
        )
    elif types.is_string(how_to_fetch):
        print_how_to_fetch_json = "tail -n +3 $(location {})".format(
            how_to_fetch,
        )
    else:
        fail("`how_to_fetch` must be str/dict, not {}".format(how_to_fetch))

    package_feature = name + "-fetched-package-feature"
    private_do_not_use_feature_json_genrule(
        name = package_feature,
        deps = [
            # We want to re-fetch packages if the fetching mechanics change.
            # `def fake_macro_library` has more details.
            "//fs_image/buck:fetched_package_layer",
        ] + fetcher.extra_deps,
        output_feature_cmd = """
        {print_how_to_fetch_json} |
            $(exe {fetch_package}) {quoted_package} {quoted_target} > "$OUT"
        """.format(
            fetch_package = fetcher.fetch_package,
            quoted_package = shell.quote(package),
            quoted_target = shell.quote(normalize_target(":" + name)),
            print_how_to_fetch_json = print_how_to_fetch_json,
        ),
        visibility = visibility,
    )

    mount_config = name + "-fetched-package-mount-config"
    buck_genrule(
        name = mount_config,
        out = "partial_mountconfig.json",  # It lacks `build_source`, e.g.
        bash = '''
        {print_how_to_fetch_json} |
            $(exe {print_mount_config}) {quoted_package} > "$OUT"
        '''.format(
            print_mount_config = fetcher.print_mount_config,
            quoted_package = shell.quote(package),
            print_how_to_fetch_json = print_how_to_fetch_json,
        ),
    )

    image_layer(
        name = name,
        features = [":" + package_feature],
        mount_config = ":" + mount_config,
        visibility = visibility,
    )
