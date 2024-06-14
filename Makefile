PROJECT = erlroute

# --------------------------------------------------------------------
# Support being sub-project
# --------------------------------------------------------------------

ifeq ($(shell basename $(shell dirname $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST)))))), deps)
    DEPS_DIR ?= $(shell dirname $(CURDIR))
endif

# --------------------------------------------------------------------
# Defining OTP version for this project which uses by kerl
# --------------------------------------------------------------------

ifneq ($(shell basename $(shell dirname $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST)))))), deps)
ERLANG_OTP = OTP-$(shell cat ./.env | grep ERLANG_VERSION | sed -e s/^ERLANG_VERSION=//)
endif

# our includes (must rid after refactoring, esp. erlpusher, erlroute)
OUR_INCS += $(DEPS_DIR)/teaser/include

ERLC_OPTS += +warn_export_vars +warn_shadow_vars +warn_obsolete_guard +warn_export_all +warn_unused_import +warn_untyped_record +warn_missing_spec_all -Werror +debug_info

dep_teaser = git https://github.com/spylik/teaser develop

DEPS = parse_trans

TEST_DEPS = teaser poolboy
PLT_APPS = poolboy

ifeq ($(USER),travis)
	ERLC_OPTS += +warn_export_vars +warn_shadow_vars +warn_obsolete_guard +warn_missing_spec -Werror
    TEST_DEPS += covertool
	dep_covertool = git https://github.com/idubrov/covertool
endif

# --------------------------------------------------------------------
# Development enviroment ("make shell" to run it).
# --------------------------------------------------------------------

comma:= ,
empty:=
space:= $(empty) $(empty)

ERL_COMPILER_OPTIONS = [$(subst $(space),$(comma),$(addsuffix "}, $(addprefix {i$(comma)", $(OUR_INCS))))]
export ERL_COMPILER_OPTIONS

SHELL_DEPS = sync lager

SHELL_OPTS = -mode interactive -kernel shell_history enabled -pa ebin/ test/ -I -env ERL_LIBS deps -env LOGGER_CHARS_LIMIT unlimited -env LOGGER_DEPTH unlimited -eval 'sync:start(), sync:onsync(fun(Mods) -> [eunit:test(Mod) || Mod <- Mods] end), [lists:map(fun(Module) -> code:ensure_loaded(list_to_atom(lists:takewhile(fun(X) -> X /= 46 end, lists:subtract(Module,Dir)))) end, filelib:wildcard(Dir++"*.erl")) || Dir <- ["src/","test/"], ok =:= filelib:ensure_dir(Dir)]'

include erlang.mk
