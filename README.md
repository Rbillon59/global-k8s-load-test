
You can follow the full tutorial here : https://romain-billon.medium.com/worldwide-load-testing-with-jmeter-and-kubernetes-on-google-cloud-platform-e86b5d75f064

# JMeter k8s startekit

This is a template repository from which you can start load testing faster when injecting load from a kubernetes cluster.

You will find inside it the necessary to organize and run your performance scenario. There is also a node monitoring tool which will monitor all your injection nodes. As well an embeded live monitoring with InfluxDB and Grafana

Thanks to [Kubernauts](https://github.com/kubernauts/jmeter-kubernetes) for the inspiration !


## Getting started

Prerequisites : 
- A kubernetes cluster (of course)
- kubectl installed and a usable context to work with
- (Optionnal) A JMeter scenario (the default one attack Google.com)

### 1. Preparing the repository

You need to put your JMeter project inside the `scenario` folder, inside a folder named after the JMX (without the extension).
Put your CSV file inside the `dataset` folder, child of `scenario`
Put your JMeter modules (include controlers) inside the `module` folder, child of `scenario`

`dataset`and `module`are in `scenario` and not below inside the `<project>` folder because, in some cases, you can have multiple JMeter projects that are sharing the JMeter modules (that's the goal of using modules after all).


*Below a visual representation of the file structure*

```bash
+-- scenario
|   +-- dataset
|   +-- module
|   +-- my-scenario
|       +-- my-scenario.jmx
|       +-- .env
```

### 2. Deploying the Stack

`kubectl apply -R -f k8s`

This will deploy all the needed applications :

- JMeter master and slaves
- Telegraf operator to automatically monitor the specified applications
- Telegraf as a DaemonSet on all the nodes
- InfluxDB to store the date (with a 5GB volume in a PVC)
- Grafana with a LB services and 4 included dashboard
- Wiremock

### 3. Starting the test

`./start_test.sh -j my-scenario.jmx -n default -c -m -i 20 -r`

Usage :
```sh
   -j <filename.jmx>
   -n <namespace >for namespace previously created (default the last created with the deploy script)
   -c flag to split and copy csv if you use csv in your test
   -m flag to copy fragmented jmx present in scenario/project/module if you use include controller and external test fragment
   -i <injectorNumber> to scale slaves pods to the desired number of JMeter injectors
   -r flag to enable report generation at the end of the test
```


**The script will :**

- Delete and create again the JMeter jobs.
- Scale the JMeter slave deployment to the desired number of injectors
- Wait to all the slaves pods to be available. Here, available means that the filesystem is reacheable (liveness probe that cat a file inside the fs)
- If needed will split the CSV locally then copy them inside the slave pods
- If needed will upload the JMeter modules inside the slave pods
- Send the JMX file to each slave pods
- Generate and send a shell script to the slaves pods to download the necessary plugins and launch the JMeter server.
- Send the JMX to the controller 
- Generate a shell script and send it to the controller to wait for all pods to have their JMeter slave port listening (TCP 1099) and launch the performance test.



### 4. Gethering results from the master pod

You can run `kubectl cp -n <namespace> <master-pod-id>:/opt/jmeter/apache-jmeter/bin/<result> $PWD/<local-result-name>`  
You can do this for the generated report and the JTL for example.  
