#!/usr/bin/env python3
import sys

from compiler.provides import ProvidesDirectory
from compiler.requires import require_directory
from tests.temp_subvolumes import TempSubvolumes

from ..make_dirs import MakeDirsItem

from .common import BaseItemTestCase, DUMMY_LAYER_OPTS, render_subvol


class MakeDirsItemTestCase(BaseItemTestCase):

    def test_make_dirs(self):
        self._check_item(
            MakeDirsItem(from_target='t', into_dir='x', path_to_make='y/z'),
            {ProvidesDirectory(path='x/y'), ProvidesDirectory(path='x/y/z')},
            {require_directory('x')},
        )

    def test_make_dirs_command(self):
        with TempSubvolumes(sys.argv[0]) as temp_subvolumes:
            subvol = temp_subvolumes.create('tar-sv')
            subvol.run_as_root(['mkdir', subvol.path('d')])

            MakeDirsItem(
                from_target='t', path_to_make='/a/b/', into_dir='/d',
                user_group='77:88', mode='u+rx',
            ).build(subvol, DUMMY_LAYER_OPTS)
            self.assertEqual(['(Dir)', {
                'd': ['(Dir)', {
                    'a': ['(Dir m500 o77:88)', {
                        'b': ['(Dir m500 o77:88)', {}],
                    }],
                }],
            }], render_subvol(subvol))

            # The "should never happen" cases -- since we have build-time
            # checks, for simplicity/speed, our runtime clobbers permissions
            # of preexisting directories, and quietly creates non-existent
            # ones with default permissions.
            MakeDirsItem(
                from_target='t', path_to_make='a', into_dir='/no_dir',
                user_group='4:0'
            ).build(subvol, DUMMY_LAYER_OPTS)
            MakeDirsItem(
                from_target='t', path_to_make='a/new', into_dir='/d',
                user_group='5:0'
            ).build(subvol, DUMMY_LAYER_OPTS)
            self.assertEqual(['(Dir)', {
                'd': ['(Dir)', {
                    # permissions overwritten for this whole tree
                    'a': ['(Dir o5:0)', {
                        'b': ['(Dir o5:0)', {}], 'new': ['(Dir o5:0)', {}],
                    }],
                }],
                'no_dir': ['(Dir)', {  # default permissions!
                    'a': ['(Dir o4:0)', {}],
                }],
            }], render_subvol(subvol))
