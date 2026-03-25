// Copyright (c) 2025, WSO2 LLC. (http://www.wso2.com).
// Licensed under the Apache License, Version 2.0.

# Validates required FHIR R4 base fields present on all resources.
#
# Checks:
#   1. `resourceType` field is present and matches ctx.resourceType
#   2. For update operations: `id` field is required
#   3. `id` format is valid if present: [A-Za-z0-9\-\.]{1,64}
public isolated class FhirBaseValidator {
    *ValidationRule;

    public isolated function validate(ValidationContext ctx) returns ValidationResult {
        // resourceType must be present and match the expected resource type
        json|error resourceTypeField = ctx.payload.resourceType;
        if resourceTypeField is error || resourceTypeField is () {
            return {valid: false, errors: ["resourceType field is required"]};
        }
        string|error resourceTypeStr = resourceTypeField.ensureType(string);
        if resourceTypeStr is error {
            return {valid: false, errors: ["resourceType must be a string"]};
        }
        if resourceTypeStr != ctx.resourceType {
            return {
                valid: false,
                errors: [string `resourceType '${resourceTypeStr}' does not match expected '${ctx.resourceType}'`]
            };
        }

        // id is required for update operations
        json|error idField = ctx.payload.id;
        if ctx.operation == "update" {
            if idField is error || idField is () || idField.toString().trim().length() == 0 {
                return {valid: false, errors: ["Field 'id' is required for update operations"]};
            }
        }

        // Validate id format if present (FHIR id: [A-Za-z0-9\-\.]{1,64})
        if !(idField is error) && !(idField is ()) {
            string idValue = idField.toString();
            if !isValidFhirId(idValue) {
                return {
                    valid: false,
                    errors: [string `Invalid 'id' format — FHIR id must be 1-64 characters matching [A-Za-z0-9\\-\\.], got: '${idValue}'`]
                };
            }
        }

        return {valid: true, errors: []};
    }

    public isolated function getName() returns string => "FhirBaseValidator";
}

isolated function isValidFhirId(string id) returns boolean {
    if id.length() == 0 || id.length() > 64 {
        return false;
    }
    return id.matches(re`[A-Za-z0-9\-\.]+`);
}
