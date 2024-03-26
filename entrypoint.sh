#!/bin/bash
git config --global --add safe.directory "*"
bundle install && bundle exec jekyll serve --livereload --host "0.0.0.0"