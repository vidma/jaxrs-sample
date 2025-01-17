# JAX-RS Sample application for Wildfly enhanced with kensu monitoring capabilities

An example of a Rest web application, using JAX-RS, Hibernate, MySQL, and Clickhouse.

The data lineages and data quality are tracked automatically between HTTP endpoints and Databases using Kensu collectors.

By default the Jaeger backend tracer is used to keep the spans published to a observability platform, 
this tracer is combined with the Kensu tracer to collect what is important for Kensu to build lineage and stats. 

Databases
----

### MySQL

#### Tutorial
The MySQL import script from the [sample MySQL database](https://www.mysqltutorial.org/mysql-sample-database.aspx/) is located in
`src/test/resources/data-mysql.sql`.

#### Kensu demodb
This instance is available on Kensu cloud and is used for the public Demos (used by Tableau).

### Clickhouse 

#### Tutorial database

You can load it as explained [here](https://clickhouse.tech/docs/en/getting-started/tutorial/).

#### Ported MySQL database

The MySQL import script from the [sample MySQL database](https://www.mysqltutorial.org/mysql-sample-database.aspx/) is
ported in `test/resources/data-clickhouse.sql` and can loaded as a regular script in Clickhouse
(`clickhouse-client < src/test/resources/data-clickhouse.sql`).

Application
----

### Sources
The application source is in the package `io.kensu.example.jboss` and consists of services:
- `VisitService`: returns data from [Clickhouse tutorial database](https://clickhouse.tech/docs/en/getting-started/tutorial/)
- `OrderDetailsService` and `ProductLineService`: querying the [sample MySQL database](https://www.mysqltutorial.org/mysql-sample-database.aspx/)

### Configuration

#### Databases

The data sources access for JPA/Hibernate are defined in `src/main/resources/META-INF/persistence.xml`.

> Note: the Demo server has its password configured as an interpolated MAVEN property whic should be set by a profile.

#### JBOSS env

* `src/main/webapp/WEB-INF/beans.xml`: enables CDI discover (Weld) for the `KensuTracerFactory` see ([Tracer Bean](#Tracer Bean)).
* `src/main/webapp/WEB-INF/jboss-deployment-structure.xml`: to avoid the default tracing capabilities of JBOSS 
  (microprofile / smallrye) to take the precedence over Kensu one (use `KensuTracerFactory` bean).

Collector
----

#### Configuration

##### Tracer Bean

* `src/main/java/io/kensu/collector/config/KensuTracerFactory.java`: Configures the Jaeger and Kensu tracers, 
  and registers it as a `Bean`.
* `src/main/resources/app.properties`: Maven interpolated file defining the application name and version.
* `src/main/resources/kensu-tracer.properties`: configures the Kensu collector (**using MAVEN interpolation to avoid committing URLs and Tokens**)
  and high level information like application (process) name, code base, user, and such.
* `src/main/resources/META-INF/services/io.opentracing.contrib.tracerresolver.TracerFactory`: Java service loader for 
  the `tracerresolver` dependency making sure that `io.opentracing.contrib.tracerresolver.TracerResolver.resolve
  picks the one we must use
  
##### Jaeger & more

Jaeger is configured using the Java properties or variable env by default, like [explained here](https://www.jaegertracing.io/docs/1.21/client-features/#tracer-configuration).

Other configurations or initializers happen in the following classes as well:

* `src/main/java/io/kensu/collector/config/DamProcessEnvironment.java`: utility to set Kensu model high level metadata
  about the application and its context (process name, run, user, code, ...).
* `src/main/java/io/kensu/collector/config/TracingContextListener.java`: makes sure `GlobalTracer` is set.


### Dependencies

#### Open Tracing
* `io.opentracing:opentracing-api`: open tracing api definitions;
* `io.opentracing.contrib:span-reporter`: to define custom, combined reporters (to jaeger and Kensu);
* `io.opentracing.contrib:opentracing-tracerresolver`: provides the mechanism to pick the right tracer;
* `io.opentracing.contrib:opentracing-jaxrs2`: injects JAX-RS request with span and tags;
* `io.jaegertracing:jaeger-client`: Jaeger backend implementation (could be made optional...).

#### Utilities
* `com.github.jsqlparser:jsqlparser`: parse SQL, used by `src/main/java/io/kensu/collector/utils/jdbc/parser/DamJdbcQueryParser.java`;
* `com.github.wnameless.json:json-flattener`: from deep JSON to flattened one, used by `src/main/java/io/kensu/collector/utils/json/KensuJsonSchemaInferrer.java`.

#### Kensu
* `io.kensio.third.contrib:opentracing-jdbc`: intercepts JDBC connection, statement, and results (added by Kensu) 
  with dedicated spans (this is a fork in `kensuio-oss`);
* `io.kensu.dim.client:java-resteasy-jackson`: Java client generated by Open API respecting JBOSS constraints (Resteasy 
  HTTP Client lib and Jackson json parser).
        
### Capabilities

#### Interceptors

* `src/main/java/io/kensu/collector/interceptors/DiscoverableSpanFinishingFilter.java`: installs for all request the 
JAX-RS `Filter` from opentracing JAX-RS support, this injects the `Span` in the request header and catches the response 
HTTP code as span tag
* `src/main/java/io/kensu/collector/interceptors/KensuTracingInterceptorFeature.java`: this decorates the span from all
  requests with additional `tags` like:
  * `http.request.url.path.pattern`: sanitized URL pattern (without values);
  * `http.request.url.path.parameters`: path parameters;
  * `http.request.url.query.parameters`: query parameters.
* `src/main/java/io/kensu/collector/interceptors/ResponseInterceptor.java`: intercepts the response to read the response 
  JSON and injects these `tags` using `src/main/java/io/kensu/collector/utils/json/KensuJsonSchemaInferrer.java`: 
  * `response.schema` the schema of the JSON;
  * `response.stats` the stats (e.g. `min`, `max`, `count`, `na.count`) of the JSON.
  
#### From (Opentracing/Kensu) JDBC
Intercepts JDBC Connection, `PreparedStatement` to inject dedicated spans with database, driver, SQLs and such information.

`Kensu` version add injection of `ResultSet` **only supported from `PreparedStatement` ATM** to compute stats while 
iterating over the `ResultSet` (e.g. `count`, `min`, `na.count`, ...);
  
#### TracerReporter (Kensu logic)
This class does the sum-up of all interceptions, injections and alike.

##### Cache
Spans being reported after completion (finish) are caught here into a `cache` where the key is the parent's `spanID` 
and the value all the children span (therefore its sibblings).

The `cache` is a `guava` one which is configured to cleaned up regularly or after a cap size is reached:
```java
 .maximumSize(10000)
 .expireAfterWrite(10, TimeUnit.MINUTES)
 ```

Cached spans are also evicted manually once used: `.invalidateAll(toBeRemoved)`.

##### Kensu business logic
When a span without `parent` is caught, then we consider the HTTP request/response done and therefore we should have
cached all spans necessary to build 
* the data sources for the HTTP endpoints and database tables
* the lineage between the data sources
* the statistics to be attached to the lineages.

> **WARNING** Lineages are `discovered` mostly and are highly constrainted (**which can be reduced with 
the interception of Hibernate mappers for example**) and limited (**lineages built in DamJdbcQueryParser should be used
to have a better support for aggregation and controls**)

The span structure looks typically as follow:
```
> GET:/v1/order-details/product-line/{productLine}
  - http.request.url.path.pattern=/v1/order-details/product-line/{productLine}?maxResults={maxResults}
  - http.request.url.query.parameters=[maxResults]

    > Query 
      - db.instance=classicmodels
      - db.statement=select orderdetai0_.orderNumber as orderNum1_0_, orderdetai0_.orderLineNumber as orderLin2_0_...    

        > QueryResultStats
          - db.column.5.md={nullable=false, type=INT, name=quantityOrdered, schemaName=, tableName=orderdetails}
          - db.column.5.stats={mean=36.875, count=16.0, sum=590.0}
          - db.count=17

    > Query 
        > QueryResultStats
        
    > Query 
        > QueryResultStats

    > serialize
      - media.type=application/json
      - response.schema=[class FieldDef { name: [].quantityOrdered fieldType: number nullable: false }, class FieldDef...
      - response.stats={[].product.productName={count=17.0}, [].product.productVendor={count=17.0}, ...
```

Deployment
----

## Install Jaeger

The Docker is perfectly OK: https://www.jaegertracing.io/docs/1.21/getting-started/#all-in-one.

## Install Wildfly

Follow instructions on https://www.wildfly.org/.

Start it in `standalone` mode: `${wildfly.home}/bin/standalone.sh`.

## Maven
Install maven following instructions on https://maven.apache.org/.

As this is using private Kensu libraries, the `$HOME/.m2/settings.xml` of maven should be updated to point to the Kensu mirrors in 
Nexus, see below.

Also to allow automatic local deployments, you enable activate the `copy-war` profile and create yours with your path to wildfly. 

Moreover, the access to Kensu API Url and Tokens are configured in `app.properties`, therefore one can configure a profile for each environment
to be used (demo101, demo102, qa3, ...) by setting the variable appropriately. The the maven build command needs to be adapted 
to use the profile like `mvn -P kensu-demo-102`

### Settings.xml
> **YOU NEED TO UPDATE IT WITH YOUR `wilfly.home` and `PUT_TOKEN_HERE`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.1.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.1.0 http://maven.apache.org/xsd/settings-1.1.0.xsd">

    <servers>
        <server>
            <id>nexus</id>
            <username>$LDAP_USER$</username>
            <password>$LDAP_PASSWORD$</password>
        </server>
    </servers>

    <mirrors>
        <mirror>
            <id>nexus</id>
            <name>nexus</name>
            <url>https://public.usnek.com/n/repository/maven-public/</url>
            <mirrorOf>*</mirrorOf>
        </mirror>
    </mirrors>
  
    <profiles>
        <profile>
            <id>kensu-demo-102</id>
            <activeByDefault/>
            <properties>
                <kensu.api.url>https://api-demo102.usnek.com</kensu.api.url>
                <kensu.api.token>${PUT_TOKEN_HERE}</kensu.api.token>
            </properties>
        </profile>
        <profile>
            <id>demodb</id>
            <activeByDefault/>
            <properties>
                <kensu.demodb.password>${PASSWORD}</kensu.demodb.password>
            </properties>
        </profile>
        <profile>
            <id>my-copy-war</id>
            <activeByDefault/>
            <properties>
                <path.to.jboss.deployments.dir>${wilfly.home}/standalone/deployments</path.to.jboss.deployments.dir>
            </properties>
        </profile>
    </profiles>
  
    <activeProfiles>
      <activeProfile>copy-war</activeProfile>
    </activeProfiles>

</settings>
```

## Dependencies
Make sure you have the collectors' dependencies installed on your maven machine, or they are published in Nexus.


## Build
To build, simply run: `mvn clean package` to create the package (`war` file).
> Note in order to inject the properties from your profiles in `settings.xml` don't forget to add the `-P` to your command!

This will compile, run the unit tests, and create a war file that can be deployed into an JEE app server.

The `war` file:

* will be created somewhere like `target/sample-service-1.3.0.war` (sensitive to `artifactId` and `version` 
  changes in `pom.xml`...).
* can be published to the `wildfly` standalone deployments folder:
  * manually: `cp target/sample-service-1.3.0.war ${wilxfly.home}/standalone/deployments`
  * automatically using a `maven profile` see [Settings.xml](#Settings.xml)

## SSL (on kensu servers)
Install certificate to your java keystore:

```sh
java.home=/Users/andy/Library/Java/JavaVirtualMachines/openjdk-15.0.1/Contents/Home/
${java.home}bin/keytool -keystore ${java.home}lib/security/cacerts -noprompt -storepass changeit -importcert \
 -trustcacerts -alias kensu_import_vault_ca -file  ~/Downloads/kensuio_vault_ca.crt
```

## Try it
Some examples:
- http://127.0.0.1:8080/rest/v1/order-details/product-line/Ships?maxResults=17
- http://127.0.0.1:8080/rest/v1/product-line/Motorcycles
- http://127.0.0.1:8080/rest/v1/product-line/Ships
- http://127.0.0.1:8080/rest/v1/order-details/count/by-product
- http://127.0.0.1:8080/rest/v1/customers/big-ones?greaterThanAmount=600

Check on Jaeger: http://localhost:16686/search

Check on Kensu UI: data catalog, lineages, and projects.
