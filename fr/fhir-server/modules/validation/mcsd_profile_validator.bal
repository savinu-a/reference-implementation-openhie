// Copyright (c) 2025, WSO2 LLC. (http://www.wso2.com).
// Licensed under the Apache License, Version 2.0.

# Validates IHE mCSD profile constraints before database writes.
#
# Checks per resource type:
#   Organization            : org-1 (name OR identifier), type 1..*, no home address/telecom (org-2/3),
#                             prohibited fields; FacilityOrganization / JurisdictionOrganization sub-profile detection
#   Location                : name, status (1..1 required + valid value), type 1..*,
#                             prohibited fields; FacilityLocation (type 2..*, managingOrganization) /
#                             JurisdictionLocation (managingOrganization) sub-profile detection
#   HealthcareService       : name, type 1..*, prohibited fields  (providedBy is 0..1 per spec — not required)
#   Endpoint                : status, connectionType, address, managingOrganization, payloadType 1..*,
#                             prohibited fields
#   OrganizationAffiliation : active, organization, participatingOrganization, code 1..*,
#                             network prohibited, prohibited fields

// mCSD CodeSystem URI used for Organization/Location type slice detection
const string MCSD_TYPE_SYSTEM =
    "https://profiles.ihe.net/ITI/mCSD/CodeSystem/IHE.mCSD.Organization.Location.Types";

public isolated class McsdProfileValidator {
    *ValidationRule;

    public isolated function validate(ValidationContext ctx) returns ValidationResult {
        string[] errors = [];
        json res = ctx.payload;

        match ctx.resourceType {
            "Organization"            => { validateOrganization(res, errors); }
            "Location"                => { validateLocation(res, errors); }
            "HealthcareService"       => { validateHealthcareService(res, errors); }
            "Endpoint"                => { validateEndpoint(res, errors); }
            "OrganizationAffiliation" => { validateOrganizationAffiliation(res, errors); }
        }

        return {valid: errors.length() == 0, errors: errors};
    }

    public isolated function getName() returns string => "McsdProfileValidator";
}

// ─── Per-resource validators ──────────────────────────────────────────────────

isolated function validateOrganization(json res, string[] errors) {
    checkProhibited(res, "implicitRules", "Organization", errors);
    checkProhibited(res, "modifierExtension", "Organization", errors);

    // org-1: SHALL have name OR at least one identifier (not both required)
    json|error nameField = res.name;
    boolean hasName = !(nameField is error) && !(nameField is ());
    json|error identifierField = res.identifier;
    boolean hasIdentifier = false;
    if !(identifierField is error) && !(identifierField is ()) {
        json[]|error ids = identifierField.ensureType();
        hasIdentifier = !(ids is error) && ids.length() > 0;
    }
    if !hasName && !hasIdentifier {
        errors.push("Organization must have name or at least one identifier (org-1)");
    }

    // type (1..*)
    requireNonEmptyArray(res, "type", "Organization.type", errors);

    // org-2: address SHALL NOT use 'home'
    checkNoHomeUse(res, "address", "Organization.address", errors);

    // org-3: telecom SHALL NOT use 'home'
    checkNoHomeUse(res, "telecom", "Organization.telecom", errors);

    // Sub-profile detection — independent checks (not mutually exclusive)
    if hasTypeCode(res, MCSD_TYPE_SYSTEM, "facility") {
        // FacilityOrganization: name (1..1) explicitly required
        if !(nameField is string) || (<string>nameField).trim().length() == 0 {
            errors.push("FacilityOrganization.name is required");
        }
    }
    if hasTypeCode(res, MCSD_TYPE_SYSTEM, "jurisdiction") {
        // JurisdictionOrganization: name (1..1) explicitly required
        if !(nameField is string) || (<string>nameField).trim().length() == 0 {
            errors.push("JurisdictionOrganization.name is required");
        }
    }
}

isolated function validateLocation(json res, string[] errors) {
    checkProhibited(res, "implicitRules", "Location", errors);
    checkProhibited(res, "modifierExtension", "Location", errors);

    // name (1..1)
    json|error nameField = res.name;
    if nameField is error || nameField is () {
        errors.push("Location.name is required");
    }

    // status (1..1) — required by mCSD, not merely validated when present
    json|error statusField = res.status;
    if statusField is error || statusField is () {
        errors.push("Location.status is required");
    } else if statusField is string {
        if statusField != "active" && statusField != "inactive" && statusField != "suspended" {
            errors.push(string `Location.status must be 'active', 'inactive', or 'suspended' — got '${statusField}'`);
        }
    }

    // type (1..*)
    requireNonEmptyArray(res, "type", "Location.type", errors);

    // Sub-profile detection
    if hasTypeCode(res, MCSD_TYPE_SYSTEM, "facility") {
        // FacilityLocation: type must have >= 2 entries
        json|error typeField = res.'type;
        if !(typeField is error) && !(typeField is ()) {
            json[]|error types = typeField.ensureType();
            if !(types is error) && types.length() < 2 {
                errors.push("FacilityLocation.type must have at least 2 entries");
            }
        }
        // managingOrganization (1..1)
        json|error mgOrgField = res.managingOrganization;
        if mgOrgField is error || mgOrgField is () {
            errors.push("FacilityLocation.managingOrganization is required");
        }
    }
    if hasTypeCode(res, MCSD_TYPE_SYSTEM, "jurisdiction") {
        // managingOrganization (1..1)
        json|error mgOrgField = res.managingOrganization;
        if mgOrgField is error || mgOrgField is () {
            errors.push("JurisdictionLocation.managingOrganization is required");
        }
    }
}

isolated function validateHealthcareService(json res, string[] errors) {
    checkProhibited(res, "implicitRules", "HealthcareService", errors);
    checkProhibited(res, "modifierExtension", "HealthcareService", errors);

    // name (1..1)
    json|error nameField = res.name;
    if nameField is error || nameField is () {
        errors.push("HealthcareService.name is required");
    }

    // type (1..*)
    requireNonEmptyArray(res, "type", "HealthcareService.type", errors);

    // Note: providedBy is 0..1 in the mCSD spec — not required
}

isolated function validateEndpoint(json res, string[] errors) {
    checkProhibited(res, "implicitRules", "Endpoint", errors);
    checkProhibited(res, "modifierExtension", "Endpoint", errors);

    // status (1..1)
    json|error statusField = res.status;
    if statusField is error || statusField is () {
        errors.push("Endpoint.status is required");
    }

    // connectionType (1..1)
    json|error connTypeField = res.connectionType;
    if connTypeField is error || connTypeField is () {
        errors.push("Endpoint.connectionType is required");
    }

    // address (1..1)
    json|error addressField = res.address;
    if addressField is error || addressField is () {
        errors.push("Endpoint.address is required");
    }

    // managingOrganization (1..1)
    json|error mgOrgField = res.managingOrganization;
    if mgOrgField is error || mgOrgField is () {
        errors.push("Endpoint.managingOrganization is required");
    }

    // payloadType (1..*)
    requireNonEmptyArray(res, "payloadType", "Endpoint.payloadType", errors);
}

isolated function validateOrganizationAffiliation(json res, string[] errors) {
    checkProhibited(res, "implicitRules", "OrganizationAffiliation", errors);
    checkProhibited(res, "modifierExtension", "OrganizationAffiliation", errors);

    // network (0..0) — prohibited by mCSD
    checkProhibited(res, "network", "OrganizationAffiliation", errors);

    // active (1..1)
    json|error activeField = res.active;
    if activeField is error || activeField is () {
        errors.push("OrganizationAffiliation.active is required");
    }

    // organization (1..1) — primary organization where the role is available
    json|error orgField = res.organization;
    if orgField is error || orgField is () {
        errors.push("OrganizationAffiliation.organization is required");
    }

    // participatingOrganization (1..1)
    json|error participatingOrgField = res.participatingOrganization;
    if participatingOrgField is error || participatingOrgField is () {
        errors.push("OrganizationAffiliation.participatingOrganization is required");
    }

    // code (1..*)
    requireNonEmptyArray(res, "code", "OrganizationAffiliation.code", errors);
}

// ─── Helper functions ─────────────────────────────────────────────────────────

// Appends an error if the given field is present (non-null) — implements 0..0 cardinality.
isolated function checkProhibited(json res, string fname, string resourceType, string[] errors) {
    if res is map<json> {
        json fieldValue = res[fname] ?: ();
        if !(fieldValue is ()) {
            errors.push(string `${resourceType}.${fname} is not allowed (must not be present)`);
        }
    }
}

// Appends an error if the given array field is absent or empty — implements 1..* cardinality.
isolated function requireNonEmptyArray(json res, string fname, string label, string[] errors) {
    if !(res is map<json>) {
        errors.push(string `${label} is required and must have at least one entry`);
        return;
    }
    json fieldValue = res[fname] ?: ();
    if fieldValue is () {
        errors.push(string `${label} is required and must have at least one entry`);
        return;
    }
    json[]|error arr = fieldValue.ensureType();
    if arr is error || arr.length() == 0 {
        errors.push(string `${label} is required and must have at least one entry`);
    }
}

// Appends an error for each element in the given array field whose `use` equals "home".
isolated function checkNoHomeUse(json res, string arrayField, string label, string[] errors) {
    if !(res is map<json>) {
        return;
    }
    json fieldValue = res[arrayField] ?: ();
    if fieldValue is () {
        return;
    }
    json[]|error items = fieldValue.ensureType();
    if items is error {
        return;
    }
    foreach json item in items {
        json|error useField = item.use;
        if useField is string && useField == "home" {
            errors.push(string `${label}.use SHALL NOT be 'home'`);
        }
    }
}

// Returns all coding objects found across all entries in res.type[].coding[].
isolated function getTypeCodings(json res) returns json[] {
    json[] result = [];
    json|error typeField = res.'type;
    if typeField is error || typeField is () {
        return result;
    }
    json[]|error types = typeField.ensureType();
    if types is error {
        return result;
    }
    foreach json typeEntry in types {
        json|error codingField = typeEntry.coding;
        if codingField is error || codingField is () {
            continue;
        }
        json[]|error codings = codingField.ensureType();
        if codings is error {
            continue;
        }
        foreach json coding in codings {
            result.push(coding);
        }
    }
    return result;
}

// Returns true if any coding in res.type[].coding[] matches both system and code.
isolated function hasTypeCode(json res, string system, string code) returns boolean {
    json[] codings = getTypeCodings(res);
    foreach json coding in codings {
        json|error sysField  = coding.system;
        json|error codeField = coding.code;
        if sysField is string && codeField is string
                && sysField == system && codeField == code {
            return true;
        }
    }
    return false;
}
