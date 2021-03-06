"This provides a more friendly UI to the image_* macros."

load(":image_cpp_unittest.bzl", "image_cpp_unittest")
load(":image_feature.bzl", "image_feature")
load(
    ":image_layer.bzl",
    "image_layer",
    "image_rpmbuild_layer",
    "image_sendstream_layer",
)
load(":image_layer_alias.bzl", "image_layer_alias")
load(":image_package.bzl", "image_package")
load(":image_python_unittest.bzl", "image_python_unittest")
load(":image_source.bzl", "image_source")

def _image_host_mount(source, mountpoint, is_directory):
    return {
        "mount_config": {
            "build_source": {"source": source, "type": "host"},
            # For `host` mounts, `runtime_source` is required to be empty.
            "default_mountpoint": source if mountpoint == None else mountpoint,
            "is_directory": is_directory,
        },
    }

def image_host_dir_mount(source = None, mountpoint = None):
    return _image_host_mount(
        source,
        mountpoint,
        is_directory = True,
    )

def image_host_file_mount(source, mountpoint = None):
    return _image_host_mount(
        source,
        mountpoint,
        is_directory = False,
    )

image = struct(
    cpp_unittest = image_cpp_unittest,
    feature = image_feature,
    host_dir_mount = image_host_dir_mount,
    host_file_mount = image_host_file_mount,
    layer = image_layer,
    layer_alias = image_layer_alias,
    opts = struct,
    package = image_package,
    python_unittest = image_python_unittest,
    rpmbuild_layer = image_rpmbuild_layer,
    sendstream_layer = image_sendstream_layer,
    source = image_source,
)
