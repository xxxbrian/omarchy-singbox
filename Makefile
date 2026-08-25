QMLLINT := /usr/lib/qt6/bin/qmllint
QML_IMPORT_DIR := $(shell mktemp -d)
QML_FILES := Panel.qml Service.qml \
	components/SingboxIcon.qml \
	components/StatRow.qml \
	components/Sparkline.qml \
	components/ConnectionSection.qml \
	components/GroupsSection.qml \
	components/ConfigSection.qml \
	components/SetupCard.qml \
	components/PanelMenu.qml

.PHONY: test test-js test-shell qml-check validate

test: test-js test-shell

# The parsing, formatting, and command-building live in plain JS precisely so
# they can be tested without a compositor. These run anywhere node does.
test-js:
	node tests/test_model.js
	node tests/test_singbox_api.js
	node tests/test_singbox_config.js

test-shell:
	bash tests/test_install.sh
	bash tests/test_panel_source.sh

# The shell's modules are `qs.Ui` and `qs.Commons`, but they live in Ui/ and
# Commons/ under the shell root, so qmllint needs an import path where a `qs`
# directory points there. Warnings are expected — the kit types are dynamic —
# but a hard parse error still fails the run.
qml-check:
	ln -sfn /usr/share/omarchy/shell $(QML_IMPORT_DIR)/qs
	$(QMLLINT) -I $(QML_IMPORT_DIR) -I /usr/lib/qt6/qml $(QML_FILES) 2>&1 \
		| (! grep -E '^Error')
	rm -rf $(QML_IMPORT_DIR)

validate: test qml-check
	omarchy plugin validate .
	git diff --check
