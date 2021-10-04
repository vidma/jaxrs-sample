# TODO:
# 13:35:44,304 INFO  [org.wildfly.extension.microprofile.opentracing] (ServerService Thread Pool -- 63) WFLYTRACEXT0001: Activating MicroProfile OpenTracing Subsystem

(docker rm -f jboss7 || true) && sleep 1 && docker run --name jboss7 \
-v $(pwd)/deployments:/home/jboss/jboss-eap-7.3/standalone/deployments \
   -p 8080:8080 -p 9990:9990 daggerok/jboss-eap-7.3:7.3.0-centos
