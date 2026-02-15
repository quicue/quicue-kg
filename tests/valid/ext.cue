package valid

import "quicue.ca/kg/ext@v0"

deriv001: ext.#Derivation & {
	id:                 "DERIV-001"
	worker:             "workers/bulk_export.py"
	output_file:        "derived/export.json"
	date:               "2026-02-15"
	description:        "Bulk export of all records"
	canon_purity:       "mixed"
	canon_sources:      ["HGNC complete gene set"]
	non_canon_elements: ["Filtering heuristic"]
	action_required:    "Review filtered records before promotion"
	input_files:        ["data/raw.json"]
	record_count:       500
}

ws001: ext.#Workspace & {
	name:        "example-app"
	description: "Multi-service application"
	components: {
		source: {
			path:        "/home/user/example-app"
			description: "Application source"
			module:      "example.com/app"
		}
		staging: {
			path:        "/srv/staging/example-app"
			description: "Staging workspace"
		}
	}
	deploy: {
		domain:    "app.example.com"
		container: "LXC 100"
		host:      "prod-host"
	}
}

ctx001: ext.#Context & {
	"@id":       "https://quicue.ca/project/quicue-kg"
	name:        "quicue-kg"
	description: "CUE-native knowledge graph framework"
	module:      "quicue.ca/kg@v0"
	status:      "active"
	license:     "Apache-2.0"
}
