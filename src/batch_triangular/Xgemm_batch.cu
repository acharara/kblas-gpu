/**
 * @copyright (c) 2012- King Abdullah University of Science and
 *                      Technology (KAUST). All rights reserved.
 **/


/**
 * @file src/batch_triangular/Xgemm_batch.cu

 * KBLAS is a high performance CUDA library for subset of BLAS
 *    and LAPACK routines optimized for NVIDIA GPUs.
 * KBLAS is provided by KAUST.
 *
 * @version 2.0.0
 * @author Ali Charara
 * @date 2017-11-13
 **/

#include <stdlib.h>
#include <stdio.h>
#include <cuda.h>
#include <cuda_runtime.h>
#include <cuda_runtime_api.h>
#include "cublas_v2.h"
#include "kblas.h"
#include "operators.h"
#include <typeinfo>

// #ifdef USE_MAGMA
// #include "magma.h"
// #endif

#include "kblas_struct.h"
#include "kblas_prec_def.h"

#include "kblas_common.h"
#include "batch_common.ch"
#include "Xhelper_funcs.ch"
#include "Xgemm_batch_core.cuh"

//=================================================================================
//Non-Strided form

/**
 * Workspace needed: device pointers
 *
 * @param[in] A_row_off row offset to sub-matrix of all A's
 * @param[in] A_col_off column offset to sub-matrix of all A's
 * @param[in] B_row_off row offset to sub-matrix of all B's
 * @param[in] B_col_off column offset to sub-matrix of all B's
 * @param[in] C_row_off row offset to sub-matrix of all C's
 * @param[in] C_col_off column offset to sub-matrix of all C's
 * @see kblasSgemm_batch() for details about rest of params.
 * A, B, C: host pointer to array of device pointers to device buffers
 */
int kblas_gemm_batch( kblasHandle_t handle,
                      char transA, char transB,
                      const int m, const int n, const int k,
                      const TYPE alpha,
                      const TYPE** A, int A_row_off, int A_col_off, int lda,
                      const TYPE** B, int B_row_off, int B_col_off, int ldb,
                      const TYPE beta,
                            TYPE** C, int C_row_off, int C_col_off, int ldc,
                      int batchCount){
  return Xgemm_batch_core(handle,
                          transA, transB,
                          m, n, k,
                          alpha,
                          A, A_row_off, A_col_off, lda,
                          B, B_row_off, B_col_off, ldb,
                          beta,
                          C, C_row_off, C_col_off, ldc,
                          batchCount);
}

// Workspace needed: none
int kblas_gemm_batch( kblasHandle_t handle,
                      char transA, char transB,
                      const int m, const int n, const int k,
                      const TYPE alpha,
                      const TYPE** A_array, int lda,
                      const TYPE** B_array, int ldb,
                      const TYPE beta,
                            TYPE** C_array, int ldc,
                      int batchCount){
  return Xgemm_batch_core(handle,
                          transA, transB,
                          m, n, k,
                          alpha,
                          A_array, 0, 0, lda,
                          B_array, 0, 0, ldb,
                          beta,
                          C_array, 0, 0, ldc,
                          batchCount);
}

// Workspace needed: none
extern "C"
int kblasXgemm_batch( kblasHandle_t handle,
                      char transA, char transB,
                      const int m, const int n, const int k,
                      const TYPE alpha,
                      const TYPE** A, int lda,
                      const TYPE** B, int ldb,
                      const TYPE beta,
                            TYPE** C, int ldc,
                      int batchCount){
  return Xgemm_batch_core(handle,
                          transA, transB,
                          m, n, k,
                          alpha,
                          A, 0, 0, lda,
                          B, 0, 0, ldb,
                          beta,
                          C, 0, 0, ldc,
                          batchCount);
}

//==============================================================================================
//Strided form

//TODO IMPORTANT: stride should be long long int since it is a memory address measure


/**
 * Uniform-size batch strided GEMM wrapper
 *
 * Workspace needed= ( __CUDACC_VER_MAJOR__ < 8 ) ? device pointers : none
 * A, B, C: host pointers to device buffers
 */
int kblas_gemm_batch( kblasHandle_t handle,
                      char transA, char transB,
                      const int m, const int n, const int k,
                      const TYPE alpha,
                      const TYPE* A, int lda, long strideA,
                      const TYPE* B, int ldb, long strideB,
                      const TYPE beta,
                            TYPE* C, int ldc, long strideC,
                      int batchCount){
  return Xgemm_batch_core(handle,
                          transA, transB,
                          m, n, k,
                          alpha,
                          A, lda, strideA,
                          B, ldb, strideB,
                          beta,
                          C, ldc, strideC,
                          batchCount);
}

// A, B, C: host pointers to device buffers
extern "C"
int kblasXgemm_batch_strided( kblasHandle_t handle,
                              char transA, char transB,
                              const int m, const int n, const int k,
                              const TYPE alpha,
                              const TYPE* A, int lda, long strideA,
                              const TYPE* B, int ldb, long strideB,
                              const TYPE beta,
                                    TYPE* C, int ldc, long strideC,
                              int batchCount){
  return Xgemm_batch_core(handle,
                          transA, transB,
                          m, n, k,
                          alpha,
                          A, lda, strideA,
                          B, ldb, strideB,
                          beta,
                          C, ldc, strideC,
                          batchCount);
}
