#!/usr/bin/env python3
import json
import os
import unittest

from contextlib import contextmanager

from btrfs_diff.tests.render_subvols import render_sendstream
from btrfs_diff.tests.demo_sendstreams_expected import render_demo_subvols
from find_built_subvol import find_built_subvol


TARGET_ENV_VAR_PREFIX = 'test_image_layer_path_to_'
TARGET_TO_PATH = {
    target[len(TARGET_ENV_VAR_PREFIX):]: path
        for target, path in os.environ.items()
            if target.startswith(TARGET_ENV_VAR_PREFIX)
}


def _pop_path(render, path):
    parts = path.split('/')
    for part in parts[:-1]:
        render = render[1][part]
    return render[1].pop(parts[-1])


class ImageLayerTestCase(unittest.TestCase):

    def setUp(self):
        # More output for easier debugging
        unittest.util._MAX_LENGTH = 12345
        self.maxDiff = 12345

    @contextmanager
    def target_subvol(self, target, mount_config=None):
        with self.subTest(target):
            # The mount configuration is very uniform, so we can check it here.
            expected_config = {
                'is_directory': True,
                'build_source': {
                    'type': 'layer',
                    'source': '//fs_image/compiler/tests:' + target,
                },
            }
            if mount_config:
                expected_config.update(mount_config)
            with open(TARGET_TO_PATH[target] + '/mountconfig.json') as infile:
                self.assertEqual(expected_config, json.load(infile))
            yield find_built_subvol(TARGET_TO_PATH[target])

    def _check_hello(self, subvol_path):
        with open(os.path.join(subvol_path, b'hello_world')) as hello:
            self.assertEqual('', hello.read())

    def _check_parent(self, subvol_path):
        self._check_hello(subvol_path)
        # :parent_layer
        for path in [
            b'usr/share/rpm_test/hello_world.tar',
            b'foo/bar/even_more_hello_world.tar',
        ]:
            self.assertTrue(
                os.path.isfile(os.path.join(subvol_path, path)),
                path,
            )
        # :feature_dirs not tested by :parent_layer
        self.assertTrue(
            os.path.isdir(os.path.join(subvol_path, b'foo/bar/baz')),
        )
        # :hello_world_base was mounted here
        self.assertTrue(os.path.exists(
            os.path.join(subvol_path, b'mounted_hello/hello_world')
        ))

        # :feature_symlinks
        for source, dest in [
            (b'foo/bar', b'foo/fighter'),
            (b'foo/bar', b'foo/face'),
            (b'foo/bar', b'foo/bar/baz/bar'),
            (b'foo/hello_world.tar', b'foo/symlink_to_hello_world.tar'),
        ]:
            self.assertTrue(
                os.path.exists(os.path.join(subvol_path, source)),
                source
            )

            self.assertTrue(
                os.path.islink(os.path.join(subvol_path, dest)),
                dest
            )

            self.assertEqual(
                os.path.join(b'/', source),
                os.readlink(os.path.join(subvol_path, dest))
            )

    def _check_child(self, subvol_path):
        self._check_parent(subvol_path)
        for path in [
            # :feature_tar_and_rpms
            b'foo/borf/hello_world',
            b'foo/hello_world',
            b'usr/share/rpm_test/mice.txt',
            b'usr/share/rpm_test/cheese2.txt',
            # :child/layer
            b'foo/extracted_hello/hello_world',
            b'foo/more_extracted_hello/hello_world',
        ]:
            self.assertTrue(os.path.isfile(os.path.join(subvol_path, path)))
        for path in [
            # :feature_tar_and_rpms ensures these are absent
            b'usr/share/rpm_test/carrot.txt',
            b'usr/share/rpm_test/milk.txt',
        ]:
            self.assertFalse(os.path.exists(os.path.join(subvol_path, path)))

    def test_image_layer_targets(self):
        # Future: replace these checks by a more comprehensive test of the
        # image's data & metadata using our `btrfs_diff` library.
        with self.target_subvol(
            'hello_world_base',
            mount_config={'runtime_source': {'type': 'chicken'}},
        ) as subvol:
            self._check_hello(subvol.path())
        with self.target_subvol(
            'parent_layer',
            mount_config={'runtime_source': {'type': 'turkey'}},
        ) as subvol:
            self._check_parent(subvol.path())
            # Cannot check this in `_check_parent`, since that gets called
            # by `_check_child`, but the RPM gets removed in the child.
            self.assertTrue(os.path.isfile(
                subvol.path('usr/share/rpm_test/carrot.txt')
            ))
        with self.target_subvol('child/layer') as subvol:
            self._check_child(subvol.path())
        with self.target_subvol('base_cheese_layer') as subvol:
            self._check_hello(subvol.path())
            self.assertTrue(os.path.isfile(
                subvol.path('/usr/share/rpm_test/cheese2.txt')
            ))
        with self.target_subvol('older_cheese_layer') as subvol:
            self._check_hello(subvol.path())
            self.assertTrue(os.path.isfile(
                subvol.path('/usr/share/rpm_test/cheese1.txt')
            ))
            # Make sure the original file is removed when the RPM is downgraded
            self.assertFalse(os.path.isfile(
                subvol.path('/usr/share/rpm_test/cheese2.txt')
            ))
        with self.target_subvol('newer_cheese_layer') as subvol:
            self._check_hello(subvol.path())
            self.assertTrue(os.path.isfile(
                subvol.path('/usr/share/rpm_test/cheese3.txt')
            ))
            # Make sure the original file is removed when the RPM is upgraded
            self.assertFalse(os.path.isfile(
                subvol.path('/usr/share/rpm_test/cheese2.txt')
            ))
        with self.target_subvol('install_toy_rpm') as subvol:
            self._check_hello(subvol.path())
            self.assertTrue(os.path.isfile(
                subvol.path('/usr/bin/toy_src_file')
            ))

    def test_layer_from_demo_sendstreams(self):
        # `btrfs_diff.demo_sendstream` produces a subvolume send-stream with
        # fairly thorough coverage of filesystem features.  This test grabs
        # that send-stream, receives it into an `image_layer`, and validates
        # that the send-stream of the **received** volume has the same
        # rendering as the original send-stream was supposed to have.
        #
        # In other words, besides testing `image_sendstream_layer`, this is
        # also a test of idempotence for btrfs send+receive.
        #
        # Notes:
        #  - `compiler/tests/TARGETS` explains why `mutate_ops` is not here.
        #  - Currently, `mutate_ops` also uses `--no-data`, which would
        #    break this test of idempotence.
        for original_name, subvol_name, mount_config in [
            ('create_ops', 'create_ops', None),
            ('create_ops', 'create_ops-from-dir', None),
            ('create_ops', 'create_ops-from-layer', None),
            ('create_ops', 'create_ops-alias', {
                'build_source': {
                    'type': 'layer',
                    'source': '//fs_image/compiler/tests:create_ops',
                }
            }),
        ]:
            with self.target_subvol(
                subvol_name, mount_config=mount_config,
            ) as sv:
                self.assertEqual(
                    render_demo_subvols(**{original_name: original_name}),
                    render_sendstream(sv.mark_readonly_and_get_sendstream()),
                )

    def test_build_appliance(self):
        with self.target_subvol('validates-build-appliance') as sv:
            r = render_sendstream(sv.mark_readonly_and_get_sendstream())

            ino, = _pop_path(r, 'bin/sh')  # Busybox from `rpm-test-milk`
            # NB: We changed permissions on this at some point, but after
            # the migration diffs land, the [75] can become a 5.
            self.assertRegex(ino, r'^\(File m[75]55 d[0-9]+\)$')

            ino, = _pop_path(r, 'var/log/yum.log')
            self.assertRegex(ino, r'^\(File m600 d[0-9]+\)$')

            # Ignore a bunch of yum & RPM spam
            for ignore_dir in [
                'usr/lib/.build-id',
                'var/cache/yum',
                'var/lib/rpm',
                'var/lib/yum',
            ]:
                ino, _ = _pop_path(r, ignore_dir)
                self.assertEqual('(Dir)', ino)

            self.assertEqual(['(Dir)', {
                'bin': ['(Dir)', {}],
                'dev': ['(Dir)', {}],
                'meta': ['(Dir)', {'private': ['(Dir)', {'opts': ['(Dir)', {
                    'artifacts_may_require_repo': ['(File d2)'],
                }]}]}],
                'usr': ['(Dir)', {
                    'lib': ['(Dir)', {}],
                    'share': ['(Dir)', {
                        'rpm_test': ['(Dir)', {
                            'milk.txt': ['(File d12)'],
                            # From the `rpm-test-milk` post-install script
                            'post.txt': ['(File d6)'],
                        }],
                    }],
                }],
                'var': ['(Dir)', {
                    'cache': ['(Dir)', {}],
                    'lib': ['(Dir)', {}],
                    'log': ['(Dir)', {}],
                    'tmp': ['(Dir)', {}],
                }],
            }], r)
