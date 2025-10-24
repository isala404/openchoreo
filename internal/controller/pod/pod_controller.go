// Copyright 2025 The OpenChoreo Authors
// SPDX-License-Identifier: Apache-2.0

package pod

import (
	"context"

	"github.com/go-logr/logr"
	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/yaml"
)

// +kubebuilder:rbac:groups="",resources=pods,verbs=get;list;watch;update;patch
// +kubebuilder:rbac:groups="",resources=pods/status,verbs=get
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch
// +kubebuilder:rbac:groups=apps,resources=daemonsets,verbs=get;list;watch
// +kubebuilder:rbac:groups=apps,resources=statefulsets,verbs=get;list;watch
// +kubebuilder:rbac:groups=apps,resources=replicasets,verbs=get;list;watch
// +kubebuilder:rbac:groups=batch,resources=jobs,verbs=get;list;watch
// +kubebuilder:rbac:groups=batch,resources=cronjobs,verbs=get;list;watch

// Reconciler reconciles a Pod object
type Reconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// Reconcile is part of the main kubernetes reconciliation loop which aims to
// move the current state of the cluster closer to the desired state.
func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	// Fetch the Pod instance for this reconcile request
	pod := &corev1.Pod{}
	if err := r.Get(ctx, req.NamespacedName, pod); err != nil {
		if apierrors.IsNotFound(err) {
			// The Pod resource may have been deleted since it triggered the reconcile
			logger.Info("Pod resource not found. Ignoring since it must be deleted.")
			return ctrl.Result{}, nil
		}
		// Error reading the object
		logger.Error(err, "Failed to get Pod")
		return ctrl.Result{}, err
	}

	// Add your pod watching logic here
	logger.Info("Reconciling Pod", "podName", pod.Name, "podNamespace", pod.Namespace, "phase", pod.Status.Phase)

	// Get parent objects and their YAML
	r.logParentObjects(ctx, pod)

	return ctrl.Result{}, nil
}

// logParentObjects finds and logs the YAML of all parent objects for a pod
func (r *Reconciler) logParentObjects(ctx context.Context, pod *corev1.Pod) {
	logger := log.FromContext(ctx)

	// Check for owner references
	if len(pod.OwnerReferences) == 0 {
		logger.Info("Pod has no owner references", "podName", pod.Name, "podNamespace", pod.Namespace)
		return
	}

	for _, ownerRef := range pod.OwnerReferences {
		if err := r.getParentObjectYAML(ctx, pod.Namespace, ownerRef, logger); err != nil {
			logger.Error(err, "Failed to get parent object YAML",
				"ownerKind", ownerRef.Kind,
				"ownerName", ownerRef.Name,
				"podName", pod.Name)
			continue
		}
	}
}

// getParentObjectYAML fetches a parent object and logs its YAML
func (r *Reconciler) getParentObjectYAML(ctx context.Context, namespace string, ownerRef metav1.OwnerReference, logger logr.Logger) error {
	var obj client.Object
	var gvk schema.GroupVersionKind

	// Determine the object type based on owner reference kind
	switch ownerRef.Kind {
	case "Deployment":
		obj = &appsv1.Deployment{}
		gvk = schema.GroupVersionKind{Group: "apps", Version: "v1", Kind: "Deployment"}
	case "DaemonSet":
		obj = &appsv1.DaemonSet{}
		gvk = schema.GroupVersionKind{Group: "apps", Version: "v1", Kind: "DaemonSet"}
	case "StatefulSet":
		obj = &appsv1.StatefulSet{}
		gvk = schema.GroupVersionKind{Group: "apps", Version: "v1", Kind: "StatefulSet"}
	case "ReplicaSet":
		obj = &appsv1.ReplicaSet{}
		gvk = schema.GroupVersionKind{Group: "apps", Version: "v1", Kind: "ReplicaSet"}
	case "Job":
		obj = &batchv1.Job{}
		gvk = schema.GroupVersionKind{Group: "batch", Version: "v1", Kind: "Job"}
	case "CronJob":
		obj = &batchv1.CronJob{}
		gvk = schema.GroupVersionKind{Group: "batch", Version: "v1", Kind: "CronJob"}
	default:
		logger.Info("Unsupported owner kind", "kind", ownerRef.Kind, "name", ownerRef.Name)
		return nil
	}

	// Set the GVK for the object
	obj.GetObjectKind().SetGroupVersionKind(gvk)

	// Fetch the object
	if err := r.Get(ctx, client.ObjectKey{Namespace: namespace, Name: ownerRef.Name}, obj); err != nil {
		if apierrors.IsNotFound(err) {
			logger.Info("Parent object not found", "kind", ownerRef.Kind, "name", ownerRef.Name)
			return nil
		}
		return err
	}

	// Convert to YAML
	yamlData, err := yaml.Marshal(obj)
	if err != nil {
		return err
	}

	// Log the YAML
	logger.Info("Parent object YAML",
		"kind", ownerRef.Kind,
		"name", ownerRef.Name,
		"namespace", namespace,
		"yaml", string(yamlData))

	return nil
}

// SetupWithManager sets up the controller with the Manager.
func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&corev1.Pod{}).
		Complete(r)
}
