# Sphinx configuration for ParamLib
import os
import sys
import sphinx_rtd_theme

project = 'ParamLib'
copyright = '2026, ParamLib Team'
author = 'ParamLib Team'

extensions = [
    'breathe',
    'sphinx.ext.autodoc',
    'sphinx_rtd_theme',
    'sphinx.ext.napoleon',
]

# Breathe Configuration
breathe_projects = {
    "paramlib": "./doxygen/paramlib/xml",
    "paramlsp": "./doxygen/paramlsp/xml",
    "paramkit_vsc": "./doxygen/paramkit_vsc/xml",
    "paramkit_modules": "./doxygen/paramkit_modules/xml",
}
breathe_default_project = "paramlib"

templates_path = ['_templates']
exclude_patterns = ['_build', 'Thumbs.db', '.DS_Store', 'doxygen']

html_theme = 'sphinx_rtd_theme'
html_static_path = ['_static']

source_suffix = {
    '.rst': 'restructuredtext',
    '.md': 'markdown',
}
