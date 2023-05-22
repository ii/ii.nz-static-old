+++
title = "Building a data pipeline for displaying Kubernetes public artifact traffic"
author = ["Caleb Woodbine"]
date = 2021-08-24
lastmod = 2021-08-24T16:42:13+12:00
categories = ["learning"]
draft = false
weight = 2001
summary = "How ii built a pipeline for Kubernetes public artifact traffic"
+++

## Introduction {#introduction}

ii is a member of the [Kubernetes Infra working group](https://github.com/kubernetes/community/blob/master/wg-k8s-infra/README.md), the group responsible for defining and managing the infrastructure for the Kubernetes project.
The infrastructure includes but is not limited to:

- [prow.k8s.io](https://prow.k8s.io)
- [Slack infra](https://github.com/kubernetes/k8s.io/tree/main/apps/slack-infra)
- [DNS records](https://github.com/kubernetes/k8s.io/tree/main/dns)
- [k8s.io redirects](https://github.com/kubernetes/k8s.io/blob/main/apps/k8s-io/README.md)
- project and resource management for SIGs and WGs

One of goals of the group is to discover where the costs are coming from and encorage large traffic users to self-host / cache the artifacts on their side, as well as to spend the funds better for the entirety of the Kubernetes infrastructure.
In order to do this, we first need to discover where the traffic is coming from.

With access to a bucket containing the logs of traffic over a certain time period, we're able to parse it and calculate a few things.

Organisations publish and advertise their IP addresses through [BGP](https://en.wikipedia.org/wiki/Border%5FGateway%5FProtocol), a fundamental sub-sytem of the internet.
IP addresses are published in blocks (subnetted) in [ASN](https://en.wikipedia.org/wiki/Autonomous%5Fsystem%5F%28Internet%29) data.
With that in mind, the ASN data of cloud-providers and organisations that fund the CNCF for Kubernetes are publically available, through this we're able to figure out the Kubernetes Infra project should communicate to about their traffic usage.

## Considering steps {#considering-steps}

At the beginning, the pieces of this puzzle were less known so it was considered to be something like this

<img style='margin-left: auto; margin-right: auto;' alt='asn-data-pipeline-plan' src='/images/2021/asn-data-pipeline-plan.svg'>

## Planning out the pipeline {#planning-out-the-pipeline}

After some more research and discovery, here is the pipeline architecture

<img style='margin-left: auto; margin-right: auto;' alt='asn-data-pipeline' src='/images/2021/asn-data-pipeline.svg'>

Our data sources are:

- global ASN data ([Potaroo](https://bgp.potaroo.net/), [PyASN](https://github.com/hadiasghari/pyasn))
- ASN-to-vendor metadata YAML
- Kubernetes public artifact logs

ii is a heavy user of Postgres for data transformation and processing (see [APISnoop and SnoopDB](https://github.com/cncf/apisnoop/tree/main/apps/snoopdb)).
Using these sources, we'll do processing in a Postgres container and in BigQuery.
We're using BigQuery, since we'll need to display the data in DataStudio for our [bi-weekly Thursday (NZT) wg-k8s-infra meetings](https://github.com/kubernetes/community/blob/master/wg-k8s-infra/README.md#meetings).

The data will need to be reproducible via the job running once again.

## Finding ASN databases {#finding-asn-databases}

ASN data is important for this operation, because it allows us to find who owns the IP addresses which are making requests to the artifact servers via the logs.
All ASN data is public, which makes it easy to discover these IP blocks from ASNs and match them to their known owner.

In the pipeline, PyASN is used with some custom logic to parse ASN data provided by the Potaroo ASN database (which could be any provider).

## The pipeline of the ASN and IP to vendor discussion {#the-pipeline-of-the-asn-and-ip-to-vendor-discussion}

<img style='margin-left: auto; margin-right: auto;' alt='asn-ip-pipeline' src='/images/2021/asn-ip-pipeline.svg'>

## Gathering the ASNs of CNCF supporting organisations {#gathering-the-asns-of-cncf-supporting-organisations}

There are quite a number of organisations that support the CNCF and consume Kubernetes artifacts.
After considering a handful of organsations to begin with, the ASNs are discovered through sites like [PeeringDB](https://www.peeringdb.com/) and committing into some files in this repo
[k8s.io/registry.k8s.io/infra/meta/asns](https://github.com/kubernetes/k8s.io/tree/main/registry.k8s.io/infra/meta/asns)
for later parsing and reading.

The ASNs are reviewed and verified by a member of the organisation that ii has a relationship with or someone through the relationship. Some organisations may not wish to verify this collected public data, in that case we will just trust it.

The metadata file will also contain directions on a later service to possibly handle the redirections to the closest cloud-provider, based on the request.

## Kubernetes Public Artifact Logs {#kubernetes-public-artifact-logs}

A GCP project in the Kubernetes org was provisioned to house the PII (Publicly Identifing Information) logs of the [GCR](https://cloud.google.com/container-registry/) logs and artifacts logs in a [GCS](https://cloud.google.com/storage) bucket.

## Postgres processing {#postgres-processing}

The largest part of the data transformation happens in a Postgres Pod, running as a Prow Job.
Firstly, we bring up Postgres and begin to run the pg-init scripts.

A dataset is created in the _kubernetes-public-ii-sandbox_ project, Potaroo pre-processed data is downloaded along with PyASN data, and PyASN data is converted for use.

```shell
bq mk \
    --dataset \
    --description "etl pipeline dataset for ASN data from CNCF supporting vendors of k8s infrastructure" \
    "${GCP_PROJECT}:${GCP_BIGQUERY_DATASET}_$(date +%Y%m%d)"
# ...
gsutil cp gs://ii_bq_scratch_dump/potaroo_company_asn.csv  /tmp/potaroo_data.csv
# ...
pyasn_util_download.py --latest
# ...
python3 /app/ip-from-pyasn.py /tmp/potaroo_asn.txt ipasn_latest.dat /tmp/pyAsnOutput.csv
```

(see [stage get dependencies](https://github.com/ii/org/blob/main/research/asn-data-pipeline/asn%5Fpipeline%5Fdocker%5Ffile.org#get-dependencies))

Tables are created so that the data can be stored and processed.
(see [migrate schemas](https://github.com/ii/org/blob/main/research/asn-data-pipeline/asn%5Fpipeline%5Fdocker%5Ffile.org#migrate-schemas))

Data is now loaded from the local ASN data and outputted as CSV for use shortly.

```sql-mode
copy (select * from pyasn_ip_asn_extended) to '/tmp/pyasn_expanded_ipv4.csv' csv header;
```

(see [stage load PyASN data into Postgres](https://github.com/ii/org/blob/main/research/asn-data-pipeline/asn%5Fpipeline%5Fdocker%5Ffile.org#load-pyasn-data-into-postgres))

The data is now uploaded to ASN BigQuery for later use.

Next, the vendor ASN metadata is downloaded from GitHub

```shell
for VENDOR in ${VENDORS[*]}; do
  curl -s "https://raw.githubusercontent.com/kubernetes/k8s.io/main/registry.k8s.io/infra/meta/asns/${VENDOR}.yaml" \
      | yq e . -j - \
      | jq -r '.name as $name | .redirectsTo.registry as $redirectsToRegistry | .redirectsTo.artifacts as $redirectsToArtifacts | .asns[] | [. ,$name, $redirectsToRegistry, $redirectsToArtifacts] | @csv' \
        > "/tmp/vendor/${VENDOR}_yaml.csv"
  bq load --autodetect "${GCP_BIGQUERY_DATASET}_$(date +%Y%m%d).vendor_yaml" "/tmp/vendor/${VENDOR}_yaml.csv" asn_yaml:integer,name_yaml:string,redirectsToRegistry:string,redirectsToArtifacts:string
done
```

along with the IP blocks from major cloud-providers and uploaded to BigQuery

```shell
curl "https://download.microsoft.com/download/7/1/D/71D86715-5596-4529-9B13-DA13A5DE5B63/ServiceTags_Public_20210802.json" \
    | jq -r '.values[] | .properties.platform as $service | .properties.region as $region | .properties.addressPrefixes[] | [., $service, $region] | @csv' \
      > /tmp/vendor/microsoft_raw_subnet_region.csv
curl 'https://www.gstatic.com/ipranges/cloud.json' \
    | jq -r '.prefixes[] | [.ipv4Prefix, .service, .scope] | @csv' \
      > /tmp/vendor/google_raw_subnet_region.csv
curl 'https://ip-ranges.amazonaws.com/ip-ranges.json' \
    | jq -r '.prefixes[] | [.ip_prefix, .service, .region] | @csv' \
      > /tmp/vendor/amazon_raw_subnet_region.csv
```

and the PeeringDB tables are downloaded via the API

```shell
mkdir -p /tmp/peeringdb-tables
PEERINGDB_TABLES=(
    net
    poc
)
for PEERINGDB_TABLE in ${PEERINGDB_TABLES[*]}; do
    curl -sG "https://www.peeringdb.com/api/${PEERINGDB_TABLE}" | jq -c '.data[]' | sed 's,",\",g' > "/tmp/peeringdb-tables/${PEERINGDB_TABLE}.json"
done
```

(see [stage load into BigQuery dataset and prepare vendor data](https://github.com/ii/org/blob/main/research/asn-data-pipeline/asn%5Fpipeline%5Fdocker%5Ffile.org#load-into-bigquery-dataset-and-prepare-vendor-data))

The Potaroo ASN data is now joined with the PeeringDB data to add company name, website, and email.

```sql-mode
copy (
  select distinct asn.asn,
  (net.data ->> 'name') as "name",
  (net.data ->> 'website') as "website",
  (poc.data ->> 'email') as email
  from asnproc asn
  left join peeriingdbnet net on (cast(net.data::jsonb ->> 'asn' as bigint) = asn.asn)
  left join peeriingdbpoc poc on ((poc.data ->> 'name') = (net.data ->> 'name'))
order by email asc) to '/tmp/peeringdb_metadata_prepare.csv' csv header;
```

It is then exported as CSV and uploaded to the BigQuery dataset.
(see [stage load and combind PeeringDB + Potaroo ASN data](https://github.com/ii/org/blob/main/research/asn-data-pipeline/asn%5Fpipeline%5Fdocker%5Ffile.org#load-and-combine-peeringdb--potaroo-asn-data))

The Kubernetes Public Artifact Logs are then loaded into the BigQuery dataset in a table as the raw usage logs.
(see [stage load Kubernetes Public Artifact Traffic Logs into BigQuery from GCS bucket](https://github.com/ii/org/blob/main/research/asn-data-pipeline/asn%5Fpipeline%5Fdocker%5Ffile.org#load-kubernetes-public-artifact-traffic-logs-into-bigquery-from-gcs-bucket))

Several queries are run against the BigQuery dataset to create some more handy tables, such as

- distinct IP count [from logs]; and
- company name to ASN and IP block

(see [stage create tables in BigQuery for use in DataStudio dashboard](https://github.com/ii/org/blob/main/research/asn-data-pipeline/asn%5Fpipeline%5Fdocker%5Ffile.org#create-tables-in-bigquery-for-use-in-datastudio-dashboard))

With the heavy processing of the IPs done over in BigQuery, the data is pulled back through into Postgres with matches on IP to IP ranges. This is useful matching IP to IP range and then IP range to ASN.

```sql-mode
copy
  (
    SELECT
      vendor_expanded_int.cidr_ip,
      vendor_expanded_int.start_ip,
      vendor_expanded_int.end_ip,
      vendor_expanded_int.asn,
      vendor_expanded_int.name_with_yaml_name,
      cust_ip.c_ip FROM vendor_expanded_int,
      cust_ip
    WHERE
      cust_ip.c_ip >= vendor_expanded_int.start_ip_int
    AND
      cust_ip.c_ip <= vendor_expanded_int.end_ip_int
  )
TO '/tmp/match-ip-to-iprange.csv' CSV HEADER;
```

The data is then pushed back to the BigQuery dataset, ready to be used.
(see [stage prepare local data of IP to IP range in Postgres](https://github.com/ii/org/blob/main/research/asn-data-pipeline/asn%5Fpipeline%5Fdocker%5Ffile.org#prepare-local-data-of-ip-to-ip-range-in-postgres))

Addition tables in the BigQuery dataset are then made for joining

- usage data to IPs
- company to IP

with that all done, the dataset is complete.
(see [stage connect all the data in the dataset of BigQuery together](https://github.com/ii/org/blob/main/research/asn-data-pipeline/asn%5Fpipeline%5Fdocker%5Ffile.org#connect-all-the-data-in-the-dataset-of-bigquery-together))

The last step of data processing is promoting the tables in the dataset to the _latest_ / _stable_ dataset which is picked up my DataStudio.
(see [stage override the existing data used in the DataStudio report](https://github.com/ii/org/blob/main/research/asn-data-pipeline/asn%5Fpipeline%5Fdocker%5Ffile.org#prepare-local-data-of-ip-to-ip-range-in-postgres))

## DataStudio report {#datastudio-report}

From the data produced, dashboards such as these can be made.

General stats

<img style='margin-left: auto; margin-right: auto;' alt='k8s-infra-datastudio-repo-overview' src='/images/2021/k8s-infra-datastudio-repo-overview.png'>

IP count and GB of traffic

<img style='margin-left: auto; margin-right: auto;' alt='k8s-infra-datastudio-repo-ip-to-image' src='/images/2021/k8s-infra-datastudio-repo-ip-to-image.png'>

(Please note: IPs and vendors will not be visible in report)

Download cost per-image

<img style='margin-left: auto; margin-right: auto;' alt='k8s-infra-datastudio-repo-cost-per-image' src='/images/2021/k8s-infra-datastudio-repo-cost-per-image.png'>

## Moving forward {#moving-forward}

The Kubernetes Infra Working Group (soon SIG) begun the effort to migrate infrastructure off Google owned GCP projects some time ago.
Through the use of this data, ii + CNCF + Kubernetes Infra WG will be able to reduce costs by assisting organisations who are pulling heavily from Kubernetes Artifact services migrate to their own hosted services.

An action item for the community is to reduce the size of artifacts, see <https://github.com/kubernetes/kubernetes/issues/102493>.

This container image is intended to be deployed into production as a Prow Job soon, so that the community can review its traffic cost per vendor, per IP, and per artifact.

## Credits and special thanks to {#credits-and-special-thanks-to}

- [Berno Kleinhans](/author/berno-kleinhans) for data discovery, manipulation, and pipeline building
- [Riaan Kleinhans](/author/riaan-kleinhans) for preparing the data and pulling it into a DataStudio report
- [Zach Mandeville](/author/zach-mandeville) for being incredible at building out database queries
- Arnaud Meukam and Aaron Crickenberger both for time and energy to support implementing the infrastructure and access to it, advice on our changes and approaches, and for merging in what ii was in need of for doing this Prow Job
