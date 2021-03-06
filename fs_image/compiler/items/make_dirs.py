#!/usr/bin/env python3
import os

from subvol_utils import Subvol

from compiler.provides import ProvidesDirectory
from compiler.requires import require_directory

from .common import coerce_path_field_normal_relative, ImageItem, LayerOpts
from .stat_options import (
    build_stat_options, customize_stat_options, STAT_OPTION_FIELDS,
)


class MakeDirsItem(metaclass=ImageItem):
    fields = ['into_dir', 'path_to_make'] + STAT_OPTION_FIELDS

    def customize_fields(kwargs):  # noqa: B902
        coerce_path_field_normal_relative(kwargs, 'into_dir')
        coerce_path_field_normal_relative(kwargs, 'path_to_make')
        # Unlike files, leave directories as writable by the owner by
        # default, since it's reasonable for files to be added at runtime.
        customize_stat_options(kwargs, default_mode=0o755)

    def provides(self):
        inner_dir = os.path.join(self.into_dir, self.path_to_make)
        while inner_dir != self.into_dir:
            yield ProvidesDirectory(path=inner_dir)
            inner_dir = os.path.dirname(inner_dir)

    def requires(self):
        yield require_directory(self.into_dir)

    def build(self, subvol: Subvol, layer_opts: LayerOpts):
        outer_dir = self.path_to_make.split('/', 1)[0]
        inner_dir = subvol.path(os.path.join(self.into_dir, self.path_to_make))
        subvol.run_as_root(['mkdir', '-p', inner_dir])
        build_stat_options(
            self, subvol, subvol.path(os.path.join(self.into_dir, outer_dir)),
        )
