// Copyright 2025 The OpenChoreo Authors
// SPDX-License-Identifier: Apache-2.0

package pod

import (
	"context"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
)

var _ = Describe("Pod Controller", func() {
	Context("When a pod is created", func() {
		It("Should reconcile successfully", func() {
			pod := &corev1.Pod{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "test-pod",
					Namespace: "default",
				},
				Spec: corev1.PodSpec{
					Containers: []corev1.Container{
						{
							Name:  "test-container",
							Image: "nginx:latest",
						},
					},
				},
			}

			Expect(k8sClient.Create(context.Background(), pod)).To(Succeed())

			podKey := types.NamespacedName{
				Name:      pod.Name,
				Namespace: pod.Namespace,
			}

			createdPod := &corev1.Pod{}
			Eventually(func() error {
				return k8sClient.Get(context.Background(), podKey, createdPod)
			}).Should(Succeed())

			Expect(createdPod.Name).To(Equal("test-pod"))
		})
	})
})
