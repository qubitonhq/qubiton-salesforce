/**
 * Thin client for the QubitOn API. The apikey header is added by the QubitOn
 * Named Credential (External Credential "QubitOn"), so no key lives in code.
 */
public with sharing class QubitOnService {
    @TestVisible private static final String ENDPOINT = 'callout:QubitOn';
    @TestVisible private static final String CLIENT = 'Salesforce Connector';

    /** statusCode is the HTTP status, or null when the call itself failed (timeout, connection). */
    public class QubitOnException extends Exception { public Integer statusCode; }
    private static QubitOnException failure(String msg, Integer code) {
        QubitOnException e = new QubitOnException(msg); e.statusCode = code; return e;
    }

    @TestVisible
    private static Object post(String path, Map<String, Object> body) { return post(path, body, 20000); }
    private static Object post(String path, Map<String, Object> body, Integer timeoutMs) {
        body.put('RequestedByClient', CLIENT);
        HttpRequest req = new HttpRequest();
        req.setEndpoint(ENDPOINT + path);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(timeoutMs);
        req.setBody(JSON.serialize(body, true));
        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (CalloutException e) {
            throw failure('Callout failed for ' + path + ': ' + e.getMessage(), null);
        }
        Integer code = res.getStatusCode();
        if (code < 200 || code >= 300) {
            throw failure('HTTP ' + code + ' from ' + path + ': ' + res.getBody().left(300), code);
        }
        return JSON.deserializeUntyped(res.getBody());
    }

    private static void putIf(Map<String, Object> m, String k, String v) { if (String.isNotBlank(v)) m.put(k, v); }
    private static List<Object> asList(Object r) { return r instanceof List<Object> ? (List<Object>) r : new List<Object>{ r }; }

    // ---- Data quality ----
    public static Map<String, Object> validateAddress(String line1, String city, String state, String postalCode, String country) {
        Map<String, Object> b = new Map<String, Object>{ 'addressLine1' => line1, 'country' => country };
        putIf(b, 'city', city); putIf(b, 'state', state); putIf(b, 'postalCode', postalCode);
        return (Map<String, Object>) post('/api/address/validate', b);
    }
    public static Map<String, Object> validatePhone(String phone, String country) {
        return (Map<String, Object>) post('/api/phone/validate', new Map<String, Object>{ 'phoneNumber' => phone, 'country' => country });
    }
    public static Map<String, Object> validateEmail(String email) {
        return (Map<String, Object>) post('/api/email/validate', new Map<String, Object>{ 'emailAddress' => email });
    }
    public static Map<String, Object> validateTaxId(String companyName, String taxNumber, String taxType, String country) {
        return (Map<String, Object>) post('/api/tax/validate', new Map<String, Object>{
            'EntityName' => companyName, 'IdentityNumber' => taxNumber, 'IdentityNumberType' => taxType, 'country' => country });
    }
    public static List<Object> businessClassification(String companyName, String street, String city, String state, String postalCode, String country) {
        Map<String, Object> b = new Map<String, Object>{ 'companyName' => companyName, 'country' => country };
        putIf(b, 'address1', street); putIf(b, 'city', city); putIf(b, 'state', state); putIf(b, 'postalCode', postalCode);
        return asList(post('/api/businessclassification/lookup', b));
    }
    /** US only: needs street, city, state and 5-digit ZIP. */
    public static List<Object> corporateHierarchy(String companyName, String street, String city, String state, String zip) {
        return asList(post('/api/corporatehierarchy/lookup', new Map<String, Object>{
            'companyName' => companyName, 'addressLine1' => street, 'city' => city, 'state' => state, 'zipCode' => zip }));
    }

    /** POST /api/qubitondatalookup/lookup: resolves one QubitOn company from name, address, phone, website and DBA and
     *  returns its header (match confidence, firmographics, industry codes, certifications, payment methods, risk
     *  flags, as the plan allows). Enterprise plans only: other plans get HTTP 403. The address needs addressType,
     *  or the API answers 422 "Requested Country Not Found". Slower than the other calls (5 to 13 s live), so 30 s. */
    public static Map<String, Object> dataLookup(String companyName, String dba, String street, String city, String state,
            String postalCode, String country, String phone, String website) {
        Map<String, Object> addr = new Map<String, Object>{ 'addressType' => 'Physical', 'country' => country };
        putIf(addr, 'addressLine1', street); putIf(addr, 'city', city); putIf(addr, 'state', state); putIf(addr, 'postalCode', postalCode);
        Map<String, Object> h = new Map<String, Object>{ 'companyName' => companyName, 'entityAddresses' => new List<Object>{ addr } };
        if (String.isNotBlank(phone)) h.put('entityPhones', new List<Object>{ new Map<String, Object>{ 'phoneNumber' => phone } });
        if (String.isNotBlank(website)) h.put('URL', new List<String>{ website });
        if (String.isNotBlank(dba)) h.put('companyNameDBA', new List<String>{ dba });
        List<Object> rs = asList(post('/api/qubitondatalookup/lookup', new Map<String, Object>{ 'headerRequest' => h }, 30000));
        Map<String, Object> r = rs.isEmpty() ? null : (Map<String, Object>) rs[0];
        Object err = r == null ? null : r.get('lookupErrorResponse');
        if (r == null || r.get('headerResponse') == null || err != null)
            throw failure('No answer from /api/qubitondatalookup/lookup' + (err == null ? '' : ': ' + JSON.serialize(err).left(200)), null);
        return (Map<String, Object>) r.get('headerResponse');
    }

    /** Diversity and small-business certifications (WBE, MBE, SBE, ...); country is required. */
    public static List<Object> certificationLookup(String companyName, String street, String city, String state, String zip, String country) {
        Map<String, Object> b = new Map<String, Object>{ 'companyName' => companyName, 'country' => country };
        putIf(b, 'addressLine1', street); putIf(b, 'city', city); putIf(b, 'state', state); putIf(b, 'zipCode', zip);
        return asList(post('/api/certification/lookup', b));
    }

    // ---- Compliance ----
    public static List<Object> checkSanctions(String companyName, String country, String city, String state, String postalCode) {
        if (String.isBlank(companyName)) throw new QubitOnException('companyName is required');
        Map<String, Object> b = new Map<String, Object>{ 'companyName' => companyName };
        putIf(b, 'country', country); putIf(b, 'city', city); putIf(b, 'state', state); putIf(b, 'postalCode', postalCode);
        return asList(post('/api/prohibited/lookup', b));
    }
    public static List<Object> screenPep(String fullName, String country) {
        return asList(post('/api/pep/lookup', new Map<String, Object>{ 'name' => fullName, 'country' => country }));
    }
    /** Adverse media / fraud indicators. */
    public static Map<String, Object> entityRisk(String companyName) {
        return (Map<String, Object>) post('/api/entity/fraud/lookup', new Map<String, Object>{ 'companyName' => companyName });
    }

    /** POST /api/beneficialownership/lookup. Registry lookups are asynchronous: the first call
     *  may return ownershipTreeField.statusField = IN_PROGRESS; call again later for the tree. */
    public static List<Object> beneficialOwnership(String companyName, String countryIso2) {
        return asList(post('/api/beneficialownership/lookup', new Map<String, Object>{
            'companyName' => companyName, 'countryIso2' => countryIso2 }));
    }

    // ---- Financial risk ----
    /** category: "Credit Score", "Fail Rate" or "Bankruptcy" */
    public static Map<String, Object> riskControl(String companyName, String category, String country) {
        Map<String, Object> b = new Map<String, Object>{ 'EntityName' => companyName, 'Category' => category };
        putIf(b, 'Country', country);
        return (Map<String, Object>) post('/api/risk/riskcontrol', b);
    }
}
