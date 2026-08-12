DOMAIN = folio_sync
TEMPLATE_DIR = l10n
PO_FILES = $(wildcard l10n/*/*.po)
MO_FILES = $(PO_FILES:%.po=%.mo)
PLUGIN_NAME = FolioSync.koplugin
BUILD_DIR = build
VERSION ?= dev

MSGFMT = msgfmt
XGETTEXT = xgettext

.PHONY: all pot mo clean release

all: mo

%.mo: %.po
	$(MSGFMT) --no-hash -o $@ $<

mo: $(MO_FILES)

pot:
	mkdir -p $(TEMPLATE_DIR)
	$(XGETTEXT) --from-code=utf-8 \
		--keyword=_ \
		--keyword=C_:1c,2 --keyword=N_:1,2 --keyword=NC_:1c,2,3 \
		--package-name="FolioSync" \
		--package-version="1.0.0" \
		--output=$(TEMPLATE_DIR)/$(DOMAIN).pot \
		*.lua

release: mo
	rm -rf $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)/$(PLUGIN_NAME)
	cp *.lua $(BUILD_DIR)/$(PLUGIN_NAME)/
	cp -r l10n $(BUILD_DIR)/$(PLUGIN_NAME)/
	echo 'return "$(VERSION)"' > $(BUILD_DIR)/$(PLUGIN_NAME)/_version.lua
	find $(BUILD_DIR)/$(PLUGIN_NAME)/l10n -name '*.po' -delete
	find $(BUILD_DIR)/$(PLUGIN_NAME)/l10n -name '*.pot' -delete
	cd $(BUILD_DIR) && zip -r $(PLUGIN_NAME).zip $(PLUGIN_NAME)
	@echo "Archive: $(BUILD_DIR)/$(PLUGIN_NAME).zip"

clean:
	rm -f $(MO_FILES)
	rm -rf $(BUILD_DIR)
