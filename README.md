# QubitOn Connector for Salesforce

Validate, enrich and screen Salesforce **Accounts** and **Contacts** with the [QubitOn API](https://www.qubiton.com): address, phone, email and tax ID validation, industry classification, sanctions and denied-party screening, beneficial ownership, PEP screening, adverse media, credit score, failure rate and bankruptcy checks. Results are written back to fields on the record.

## What it does

Checks run automatically, a few seconds after a record is created, or after a field they depend on changes. They run in a background job because Salesforce does not allow API calls during a save. Errors never block the save; they are recorded in the `QubitOn Error` field.

| Object | Check | Runs when | Result field |
|---|---|---|---|
| Account | Address standardization | Billing street is set | `QubitOn_Address_Status__c`, `QubitOn_Standardized_Address__c` |
| Account | Phone validation | Phone is set | `QubitOn_Phone_Status__c` |
| Account | Tax ID verification (e.g. US EIN vs IRS records). The ID type comes from `QubitOn_Tax_ID_Type__c` (EIN, VAT, GST, ABN and others); EIN when blank | `QubitOn_Tax_ID__c` is set | `QubitOn_Tax_Status__c` |
| Account | Optional, off by default: company match through the QubitOn data lookup (enterprise plans), turned on with the `Use_Data_Lookup__c` setting: how sure the match is, what it matched on, whether the billing address matched, and in the same call the firmographics, industry codes, certifications, payment methods and risk flags below. See [Data lookup](#data-lookup) | Always (needs a name and country) | `QubitOn_Match_Confidence__c`, `QubitOn_Matched_On__c`, `QubitOn_Address_Not_Matched__c`, `QubitOn_Payment_Methods__c`, `QubitOn_Risk_Flags__c`, plus the fields in the next rows |
| Account | Industry classification: primary SIC and NAICS code, every ranked code, line of business, year started, location type and how sure the company match is (see [Industry codes](#industry-codes)) | Billing city and a state are set. The API requires a state for every country, so when the record has none the state from a successful address validation is used (e.g. `BY` for Munich) | `QubitOn_Primary_SIC__c`, `QubitOn_Primary_NAICS__c`, `QubitOn_SIC_Codes__c`, `QubitOn_NAICS_Codes__c`, `QubitOn_Line_of_Business__c`, `QubitOn_Year_Started__c`, `QubitOn_Location_Type__c`, `QubitOn_Match_Confidence__c` (High, Medium or Low), `QubitOn_Confidence_Code__c` (1 to 10), `QubitOn_Data_Source__c`, `QubitOn_Record_ID__c` |
| Account | Firmographics (employees, annual revenue, website, ticker, minority-, women- and veteran-owned, small business, nonprofit, out of business). Needs the firmographics entitlement on your QubitOn subscription | Same call as classification | `QubitOn_Employees__c`, `QubitOn_Revenue__c`, `QubitOn_Website__c`, `QubitOn_Ticker__c`, `QubitOn_Diversity__c`, `QubitOn_Out_of_Business__c`. Also fills the standard Website, Employees, Annual Revenue and Ticker Symbol fields, but only when they are blank. Annual Revenue is filled only when revenue per employee is at least $10,000, or, when the employee count is unknown, when revenue is at least $1,000,000: the API documents revenue in whole US dollars, but some source records still carry thousands or millions (for example 118200 for a company with 223,000 employees). `QubitOn_Revenue__c` always shows the value as reported |
| Account | Diversity and small-business certifications (WBE, MBE, SBE, WOSB, ...): active ones only, best match first, with the expiry date when known. `None found`, or `None active (N expired)` when every one has expired. Each list is cut at 255 characters on whole items | Always (needs a name and country) | `QubitOn_Certification_Types__c`, `QubitOn_Certification_Agencies__c`, `QubitOn_Certification_Match_Confidence__c` (High, Medium or Low) |
| Account | Corporate hierarchy (US): `Found: N related companies`, `Matched, no related companies` or `No hierarchy data` | US billing street and ZIP are set | `QubitOn_Hierarchy_Status__c` |
| Account | Sanctions / denied-party screening (100+ lists incl. OFAC, BIS, EU, UN) | Always | `QubitOn_Sanctions_Status__c`, `QubitOn_Sanctions_Detail__c` |
| Account | Adverse media and fraud indicators | Always | `QubitOn_Adverse_Media_Score__c`, `QubitOn_High_Risk__c` |
| Account | Beneficial ownership: owners (with % when the registry reports one), officers with role, each owner screened against watch lists; a hit is shown as `LIST MATCH (EPLS, OIG, ...)` with the list codes. Registry-backed; ISO2 country needed; coverage varies by country | Country is a 2-letter ISO code (see below) | `QubitOn_UBO_Status__c`, `QubitOn_UBO_Detail__c`, `QubitOn_UBO_Sanctions_Hit__c` |
| Account | Commercial credit score | Always | `QubitOn_Credit_Score__c` |
| Account | Payment failure rate | Always | `QubitOn_Fail_Rate__c` |
| Account | Bankruptcy filings | Always | `QubitOn_Bankruptcy__c` |
| Account | How sure the company match behind the three financial checks is, when the API reports it, e.g. `Credit score: Medium; Fail rate: Medium; Bankruptcy: Low` (`None` means no company was matched) | Same calls as the financial checks | `QubitOn_Risk_Match_Confidence__c` |
| Contact | Email validation (`Valid` means QubitOn's checks passed; it does not prove the mailbox exists) | Email is set | `QubitOn_Email_Status__c` |
| Contact | Politically exposed person (PEP) screening | Always | `QubitOn_PEP_Status__c`, `QubitOn_PEP_Detail__c` |

Accounts are re-checked when Name, Phone, Tax ID or any billing address field changes; Contacts when name, email or mailing country changes. Other edits do not trigger API calls.

### Data lookup (optional, off by default)

The connector uses business classification and the certification lookup unless you turn data lookup on. To turn it on: Setup, **Custom Settings**, **QubitOn Settings**, **Manage**, then a default organization level value with **Use Data Lookup** checked (or a value for a profile or user to try it on fewer people). With it off, data lookup is never called.

With it on, on plans that include it, the connector calls `/api/qubitondatalookup/lookup` first, with the Account name, billing address, phone, website and DBA (the standard `Tradestyle` field, when your org has it). When it answers, the business classification and certification calls are skipped.

- **Low match.** When the address matched none of the company's addresses, QubitOn returns the closest company with `Low` confidence and `QubitOn Address Not Matched` checked. It may be a different company, so employees, revenue, website, year started, line of business, industry codes, certifications, payment methods and risk flags stay blank, and they are never filled from another call. Out-of-business status always shows.
- **No match** leaves those fields blank too.
- **Not on your plan** (HTTP 403): the connector falls back to the business classification and certification calls, with no error. After the first 403 the other Accounts in the same job skip the data lookup.
- **Unavailable** (timeout, 5xx, any other error): the same fallback, and `QubitOn Error` says why.
- Payment methods and risk flags need those options on your QubitOn plan.
- Data lookup returns no ticker, ownership flags or 1 to 10 confidence code, so `QubitOn Ticker`, `QubitOn Diversity` and `QubitOn Confidence Code` stay blank on that path.

### Industry codes

QubitOn returns up to 5 SIC and 5 NAICS codes, ranked per type, each with a role (`primary` or `secondary`) and a confidence that it is the company's primary code (`High`, `Medium` or `Low`).

- `QubitOn Primary SIC` and `QubitOn Primary NAICS` hold the code and its description only when QubitOn marks it primary with High or Medium confidence. When every code is Low, they stay blank: the connector does not guess.
- `QubitOn SIC Codes` and `QubitOn NAICS Codes` list every code in rank order, tagged `(P, High)` for primary or `(S, Low)` for secondary with its confidence, e.g. `7372 Prepackaged Software (P, High); 7371 Custom Computer Programming Services (S, Low)`. The list is cut at 255 characters on whole codes. 8-digit SIC sub-codes are left out; their 4-digit parent is listed.
- Older API answers without rank, role or confidence still work: codes keep the API's order, carry no tag, and the primary fields stay blank.
- `QubitOn Match Confidence` (High, Medium or Low) says how sure QubitOn is that the classified company is this Account. `QubitOn Confidence Code` keeps the 1 to 10 match code (10 is the strongest). Both are blank when the API does not report them.

Company registries build ownership trees asynchronously. When the first lookup returns *In progress*, the connector re-checks after a minute, up to 3 times.

Works with or without **State and Country/Territory Picklists**: when they are enabled, the ISO country and state codes are sent. Without them, the country is sent as typed, so beneficial ownership runs only when the billing country is a 2-letter code such as `GB`. A blank country is treated as `US`, and so are an Account billing country of `United States` or `USA`. A Contact with no mailing country falls back to its Account's billing country before `US`.

## Requirements

- Salesforce Enterprise, Unlimited, Performance or Developer Edition, API version 62.0 or later
- A QubitOn API key ([sign up](https://www.qubiton.com/auth/register), then **API Keys** in the dashboard).

### What your QubitOn plan needs

The connector calls these endpoints. Ask QubitOn which ones your plan includes.

| Check | Endpoint | Notes |
|---|---|---|
| Address, phone, email, tax ID | `/api/address/validate`, `/api/phone/validate`, `/api/email/validate`, `/api/tax/validate` | |
| Certifications | `/api/certification/lookup` | |
| Data lookup | `/api/qubitondatalookup/lookup` | Enterprise plans. Without it the connector uses the classification and certification calls |
| Industry classification and firmographics | `/api/businessclassification/lookup` | Employees, revenue, website, ticker and the ownership and small-business flags need the firmographics entitlement. Without it, codes and the matched company still fill |
| Corporate hierarchy | `/api/corporatehierarchy/lookup` | US only |
| Sanctions, PEP, adverse media | `/api/prohibited/lookup`, `/api/pep/lookup`, `/api/entity/fraud/lookup` | |
| Credit score, fail rate, bankruptcy | `/api/risk/riskcontrol` | The connector does not use `/api/creditanalysis/lookup` |
| Beneficial ownership | `/api/beneficialownership/lookup` | Registry coverage varies by country |

A check your plan does not include returns an HTTP error. The connector records it in `QubitOn_Error__c` and carries on with the other checks.
- [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli) (`sf`) for the source install

## Install

```bash
git clone https://github.com/qubitonhq/qubiton-salesforce.git
cd qubiton-salesforce
sf org login web --alias my-org            # add --instance-url https://<your-domain>.my.salesforce.com for a sandbox or My Domain
sf project deploy start --target-org my-org --source-dir force-app --test-level RunSpecifiedTests --tests QubitOnTests
sf org assign permset --name QubitOn_Connector --target-org my-org
```

The deploy runs the bundled tests (41 tests, about 98% coverage), so it also works for production orgs, which require 75%.

### Store your API key

The key lives in the `QubitOn` External Credential, never in code.

**In Setup:** Named Credentials, then **External Credentials**, then **QubitOn**. Under Principals, edit **QubitOnKey** and add an Authentication Parameter named `apikey` with your key as the value.

**Or from the CLI** (works in bash and zsh; keeps the key out of your shell history):

```bash
printf 'QubitOn key: '; read -rs K; echo
printf '{"externalCredential":"QubitOn","principalName":"QubitOnKey","principalType":"NamedPrincipal","credentials":{"apikey":{"value":"%s","encrypted":true}}}' "$K" \
  | sf api request rest /services/data/v62.0/named-credentials/credential --method POST --body - --target-org my-org; unset K
```

Assign the **QubitOn Connector** permission set to every user whose edits should trigger checks; it grants access to the credential and the result fields.

### Try it

Create an Account with a billing address, phone and `Tax ID`, wait a few seconds, and refresh. Add the QubitOn fields to your page layouts to see them on the record.

### Upgrading from an earlier version

`QubitOn_Match_Confidence__c` changed from a number (the 1 to 10 confidence code) to a High/Medium/Low picklist. The number now lives in `QubitOn_Confidence_Code__c`. The deploy converts the field in place and clears its old values; they come back on the next check of each Account. Reports or flows that used the old number should switch to `QubitOn Confidence Code`.

## Using the service from your own Apex

`QubitOnService` exposes each API as a static method, for example:

```apex
List<Object> hits = QubitOnService.checkSanctions('Acme Ltd', 'GB', 'London', null, null);
Map<String, Object> addr = QubitOnService.validateAddress('1 Main St', 'Austin', 'TX', '78701', 'US');
Map<String, Object> credit = QubitOnService.riskControl('Acme Ltd', 'Credit Score', 'US');
List<Object> owners = QubitOnService.beneficialOwnership('Tesco PLC', 'GB');
```

Callouts are not allowed in triggers; call these from a Queueable, Batch or `@future(callout=true)` context.

## Limits and design

- Up to 12 API calls per Account and 2 per Contact (with data lookup on: 11 when it answers, 13 when it falls back). Jobs process 4 Accounts (3 with data lookup on; `PER_JOB` and `PER_JOB_DATA_LOOKUP` in `QubitOnAccountScreening`) or 20 Contacts at a time and chain the rest, staying under Salesforce's limits of 100 callouts and 120 seconds of callout time per transaction. The data lookup takes 5 to 13 seconds live and has a 30-second timeout; every other call has 20 seconds. Raise `PER_JOB` only if your jobs finish well inside the limit.
- Line of business is the first SIC code's description. Use `QubitOn Primary SIC` or `QubitOn Primary NAICS` when you need a primary industry: they are filled only when QubitOn is confident.
- Large backfills of existing records should be throttled to your QubitOn plan's rate limit.

## Components

| Type | Name |
|---|---|
| Apex classes | `QubitOnService`, `QubitOnAccountScreening`, `QubitOnContactScreening`, `QubitOnOwnershipRecheck`, `QubitOnTriggerGuard`, `QubitOnTests` |
| Triggers | `QubitOnAccountTrigger`, `QubitOnContactTrigger` |
| External Credential | `QubitOn` (custom auth, `apikey` header) |
| Named Credential | `QubitOn` → `https://api.qubiton.com` |
| Permission set | `QubitOn_Connector` |
| Custom fields | 44 on Account, 5 on Contact |
| Custom setting | `QubitOn_Settings__c` (hierarchy, protected): `Use_Data_Lookup__c`, off by default |

## Support

- Docs: [qubiton.com/docs](https://www.qubiton.com/docs)
- Issues: [github.com/qubitonhq/qubiton-salesforce/issues](https://github.com/qubitonhq/qubiton-salesforce/issues)
- Email: support@qubiton.com

## License

MIT, see [LICENSE](LICENSE).
