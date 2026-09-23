apiVersion: v1
kind: Pod
metadata:
  name: __POD__
  namespace: __NAMESPACE__
  labels:
    app: bf3-fw-maintenance
spec:
  nodeSelector:
    kubernetes.io/hostname: __NODE__
  tolerations:
  - key: node.kubernetes.io/unschedulable
    operator: Exists
    effect: NoSchedule
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  restartPolicy: Never
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 30
  containers:
  - name: maintenance
    image: __IMAGE__
    imagePullPolicy: IfNotPresent
    command: ["sleep", "infinity"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: host-dev
      mountPath: /dev
    - name: host-sys
      mountPath: /sys
    - name: host-modules
      mountPath: /lib/modules
      readOnly: true
    - name: work
      mountPath: /work
  volumes:
  - name: host-dev
    hostPath:
      path: /dev
      type: Directory
  - name: host-sys
    hostPath:
      path: /sys
      type: Directory
  - name: host-modules
    hostPath:
      path: /lib/modules
      type: Directory
  - name: work
    hostPath:
      path: /var/tmp/bf3-fw-update
      type: DirectoryOrCreate
