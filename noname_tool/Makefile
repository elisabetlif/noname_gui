# SPDX-FileCopyrightText: 2023 Technical University of Denmark
#
# SPDX-License-Identifier: BSD-3-Clause

SRC := app/Main.hs src/Noname.hs $(wildcard src/Noname/*.hs)
DIR := $(HOME)/.local/bin

.PHONY: all install clean test format lint

all: noname

noname: $(SRC) noname.cabal
	cabal build exe:noname
	cp $$(cabal list-bin exe:noname) noname

install: noname
	cp noname $(DIR)/noname

clean:
	cabal clean
	$(RM) noname

test: $(SRC) tests/GoldenTests.hs noname.cabal
	cabal test

format: $(SRC) tests/GoldenTests.hs noname.cabal
	fourmolu --mode inplace $(SRC) tests/GoldenTests.hs
	cabal-fmt --inplace noname.cabal

lint: $(SRC) tests/GoldenTests.hs
	hlint $(SRC) tests/GoldenTests.hs
