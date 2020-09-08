/*

Copyright (C) 2018-2020 Deep Tavker (tavkerdeep@gmail.com)
Copyright (C) 2018 Ahmad Shakibaeinia
Copyright (C) 2018 Mojtaba Jandaghian

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/


#include <algorithm>
#include <stdio.h>
#include <math.h>
#include <fstream>
#include <iostream>
#include <vector>
#include <thrust/sort.h>

using namespace std;


double *x, *y, *z;
double Xmax=9, Xmin=0;
double Ymax=9, Ymin=0;
double Zmax=9, Zmin=0;
double re=0.072, DELTA=0;
int NUM=80000;
int MAX_NEIGHB=1500;
int THREADS_PER_BLOCK=512;

void create_particles(int NUM){
    x = (double *)malloc(sizeof(double)*NUM);
    y = (double *)malloc(sizeof(double)*NUM);
    z = (double *)malloc(sizeof(double)*NUM);
    srand((unsigned)time(0)); 
    double lowest=0, highest=8; 
    double range=(highest-lowest)+1; 
    for(int index=0; index<NUM; index++){ 
        x[index] = lowest+double(range*rand()/(RAND_MAX + 1.0)); 
        y[index] = lowest+double(range*rand()/(RAND_MAX + 1.0)); 
        z[index] = lowest+double(range*rand()/(RAND_MAX + 1.0)); 
    } 
}

int **neighb, **neighb_cuda;
int *particleHash, *particleid, *cellStart, *cellEnd;

// ----------------- CUDA KERNELS -------------------------

__global__ void calcHash(double *d_x, double *d_y, double *d_z, int *d_particleHash,\
	int *d_NUM, double *d_Xmax, double *d_Xmin, double *d_re, double *d_DELTA, double *d_Ymin, \
  double *d_Ymax, double *d_Zmax, double *d_Zmin, int *d_particleid, int *d_tnc, int *ncx, int *ncy,\
  int *ncz){

  int k = threadIdx.x + blockIdx.x * blockDim.x;
  if(k < *d_NUM){

  *ncx = int((*d_Xmax - *d_Xmin) / (*d_re + *d_DELTA)) + 1;     // Number of cells in x direction
  *ncy = int((*d_Ymax - *d_Ymin) / (*d_re + *d_DELTA)) + 1;     // Number of cells in y direction
  *ncz = int((*d_Zmax - *d_Zmin) / (*d_re + *d_DELTA)) + 1;     // Number of cells in z direction
  *d_tnc = *ncx * *ncy * *ncz;

  int *icell, *jcell, *kcell, *cellNum;

  int sizeint = sizeof(int);
  icell = (int *)malloc(sizeint);
  jcell = (int *)malloc(sizeint);
  kcell = (int *)malloc(sizeint);
  cellNum = (int *)malloc(sizeint);
  
  *icell = int((d_x[k] - *d_Xmin) / (*d_re + *d_DELTA)) + 1;
  *jcell = int((d_y[k] - *d_Ymin) / (*d_re + *d_DELTA)) + 1;
  *kcell = int((d_z[k] - *d_Zmin) / (*d_re + *d_DELTA)) + 1;

  *cellNum = *icell + (*jcell - 1)* *ncx + (*kcell - 1)* *ncx * *ncy;

  d_particleHash[k] = *cellNum;
  d_particleid[k] = k;
  
  free(icell);
  free(jcell);
  free(kcell);
  free(cellNum);
}
}

__global__ void findCellStart(int *particleHash, int *cellStart, int *cellEnd, int *NUM){

  int k = threadIdx.x + blockIdx.x * blockDim.x; // here index value is equal to the cell number which starts with 1 
  if(k < *NUM){
  if (particleHash[k] != particleHash[k+1] && k!= *NUM - 1){
    cellEnd[particleHash[k] - 1] = k;
    cellStart[particleHash[k+1] - 1] = k+1;
  }
  if(k == *NUM - 1){
    cellEnd[particleHash[k] - 1] = k;
  }
    }

  free(&k);            
}

__global__ void createNeighbourArraysCUDA(int *d_neighb, int *cellStart, int *cellEnd, int *particleHash, int *particleid, int *ncx, int *ncy, int *ncz, int *d_max_neighb,  int *d_NUM){

  int index = threadIdx.x + blockIdx.x * blockDim.x; 

  if(index < *d_NUM){
  int pid, icell, jcell, kcell, cellNum;

  cellNum = particleHash[index]; 
  pid = particleid[index];
  
  int neighb_index = pid * (*d_max_neighb + 1);

  kcell = (cellNum - 1)/((*ncx) * (*ncy)) + 1;
  jcell = ((cellNum - 1) - ((kcell - 1)* (*ncx) * (*ncy)))/ *ncx + 1;
  icell = cellNum - 1 - *ncx * (jcell - 1) - (*ncx * *ncy)*(kcell - 1) + 1;

  int Cnum, J;
  int curr_neighb_num = 0;
  
  int row, colu, elev, m1, m2, m3, m4, m5, m6;
  if (icell == 1)m1 = 0; else m1 = -1;
  if (icell == *ncx)m2 = 0; else m2 = +1;
  if (jcell == 1)m3 = 0; else m3 = -1;
  if (jcell == *ncy)m4 = 0; else m4 = +1;
  if (kcell == 1)m5 = 0; else m5 = -1;
  if (kcell == *ncz)m6 = 0; else m6 = +1;

  for (row = m1; row <= m2; row++)
  {
    for (colu = m3; colu <= m4; colu++) 
    {
      for (elev = m5; elev <= m6; elev++)
      {

        Cnum = icell + row + (jcell - 1 + colu)* *ncx + (kcell - 1 + elev)* *ncx* *ncy;

        if (cellEnd[Cnum - 1] != -1){

        for (int JJ = cellStart[Cnum -1]; JJ <= cellEnd[Cnum - 1]; JJ++)
        {
          J = particleid[JJ];
          curr_neighb_num++;
          d_neighb[neighb_index + curr_neighb_num] = J+1; //here the index is shifted by one unit to conform to the original MPS convention
          
        }
      }
      }
    }
  }
  
  d_neighb[neighb_index] = curr_neighb_num;
 }
}

__global__ void InitializeCellDetails(int *cellStart, int *cellEnd, int *d_tnc){
  int index = threadIdx.x + blockIdx.x * blockDim.x; 
  if(index < *d_tnc){
  cellStart[index] = 0; cellEnd[index] = -1;
}
free(&index);
}

__global__ void Template(int *particleHash, int *particleid, int *cellStart, int *cellEnd, int *ncx, int *ncy, int *ncz, int *size_neighbours, int *test){
  int index = threadIdx.x + blockDim.x * blockIdx.x;
  int pid, icell, jcell, kcell, cellNum;
  int *neighbours;
  neighbours = (int *)malloc(*size_neighbours);
  cellNum = particleHash[index]; 
  pid = particleid[index];

  kcell = (cellNum - 1)/((*ncx) * (*ncy)) + 1;
  jcell = ((cellNum - 1) - ((kcell - 1)* (*ncx) * (*ncy)))/ *ncx + 1;
  icell = cellNum - 1 - *ncx * (jcell - 1) - (*ncx * *ncy)*(kcell - 1) + 1;

  int Cnum, J;
  int curr_neighb_num = 0;
  
  int row, colu, elev, m1, m2, m3, m4, m5, m6;
  if (icell == 1)m1 = 0; else m1 = -1;
  if (icell == *ncx)m2 = 0; else m2 = +1;
  if (jcell == 1)m3 = 0; else m3 = -1;
  if (jcell == *ncy)m4 = 0; else m4 = +1;
  if (kcell == 1)m5 = 0; else m5 = -1;
  if (kcell == *ncz)m6 = 0; else m6 = +1;

  for (row = m1; row <= m2; row++)
  {
    for (colu = m3; colu <= m4; colu++) 
    {
      for (elev = m5; elev <= m6; elev++)
      {

        Cnum = icell + row + (jcell - 1 + colu)* *ncx + (kcell - 1 + elev)* *ncx* *ncy;

        if (cellEnd[Cnum - 1] != -1){

        for (int JJ = cellStart[Cnum -1]; JJ <= cellEnd[Cnum - 1]; JJ++)
        {
          J = particleid[JJ];
          curr_neighb_num++;
          neighbours[curr_neighb_num] = J;
          
        }
      }
      }
    }
  }
  
  neighbours[0] = curr_neighb_num;
  test[pid] = curr_neighb_num; //any further operations can be done using this neighbour array
}

// ------------------------- Host sub-sub-routine for neighbour computation ------------------------ 

void neighbour_cuda_1(){

  // ------------------ variable declarations and initializations ------------------------------

  int *d_cellEnd, *d_cellStart, *d_NUM, *d_tnc, *tnc, *d_ncx, *d_ncy, *d_ncz, *d_max_neighb;
  int *d_particleHash, *d_particleid, *d_neighb, *h_neighb, *d_sizeof_neighbours;
  double *d_x, *d_y, *d_z, *d_Xmax, *d_Xmin, *d_Ymax, *d_Ymin, *d_Zmax, *d_Zmin, *d_re, *d_DELTA;

  int arrsizeint = NUM * sizeof(int);
  int sizeint = sizeof(int);
  int arrsizedouble = NUM * sizeof(double);
  int sizedouble = sizeof(double);
  int sizeneighb = NUM * (MAX_NEIGHB + 1) * sizeof(int);
  int sizeof_neighbours = (MAX_NEIGHB + 1) * sizeof(int);

  tnc = (int *)malloc(sizeint);
  h_neighb = (int *)malloc(sizeneighb);

  cudaMalloc((void **)&d_particleHash, arrsizeint);
  cudaMalloc((void **)&d_particleid, arrsizeint); 
  cudaMalloc((void **)&d_x, arrsizedouble);
  cudaMalloc((void **)&d_y, arrsizedouble);
  cudaMalloc((void **)&d_z, arrsizedouble);
  cudaMalloc((void **)&d_Xmin, sizedouble);
  cudaMalloc((void **)&d_Xmax, sizedouble);
  cudaMalloc((void **)&d_Ymin, sizedouble);
  cudaMalloc((void **)&d_Ymax, sizedouble);
  cudaMalloc((void **)&d_Zmin, sizedouble);
  cudaMalloc((void **)&d_Zmax, sizedouble);
  cudaMalloc((void **)&d_re, sizedouble);
  cudaMalloc((void **)&d_DELTA, sizedouble);
  cudaMalloc((void **)&d_NUM, sizeint);
  cudaMalloc((void **)&d_tnc, sizeint);
  cudaMalloc((void **)&d_ncx, sizeint);
  cudaMalloc((void **)&d_ncy, sizeint);
  cudaMalloc((void **)&d_ncz, sizeint);
  cudaMalloc((void **)&d_neighb, sizeneighb);
  cudaMalloc((void **)&d_max_neighb, sizeint);
  cudaMalloc((void **)&d_sizeof_neighbours, sizeof_neighbours);

  cudaMemcpy(d_x, x, arrsizedouble, cudaMemcpyHostToDevice);
  cudaMemcpy(d_y, y, arrsizedouble, cudaMemcpyHostToDevice);
  cudaMemcpy(d_z, z, arrsizedouble, cudaMemcpyHostToDevice);
  cudaMemcpy(d_Xmin, &Xmin, sizedouble, cudaMemcpyHostToDevice);
  cudaMemcpy(d_Xmax, &Xmax, sizedouble, cudaMemcpyHostToDevice);
  cudaMemcpy(d_Ymin, &Ymin, sizedouble, cudaMemcpyHostToDevice);
  cudaMemcpy(d_Ymax, &Ymax, sizedouble, cudaMemcpyHostToDevice);
  cudaMemcpy(d_Zmin, &Zmin, sizedouble, cudaMemcpyHostToDevice);
  cudaMemcpy(d_Zmax, &Zmax, sizedouble, cudaMemcpyHostToDevice);
  cudaMemcpy(d_re, &re, sizedouble, cudaMemcpyHostToDevice);
  cudaMemcpy(d_DELTA, &DELTA, sizedouble, cudaMemcpyHostToDevice);
  cudaMemcpy(d_NUM, &NUM, sizeint, cudaMemcpyHostToDevice);
  cudaMemcpy(d_max_neighb, &MAX_NEIGHB, sizeint, cudaMemcpyHostToDevice);
  cudaMemcpy(d_sizeof_neighbours, &sizeof_neighbours, sizeint, cudaMemcpyHostToDevice);
  
  // --------------- running the calcHash kernel ----------------------------------------
  
  calcHash<<<NUM/THREADS_PER_BLOCK + 1,THREADS_PER_BLOCK>>>(d_x, d_y, d_z, d_particleHash, d_NUM, d_Xmax, d_Xmin, d_re, d_DELTA, d_Ymin, d_Ymax, d_Zmax, d_Zmin, d_particleid, d_tnc, d_ncx, d_ncy, d_ncz);
  
  // ---------------- sorting the particleHash array -----------------------------

  thrust::device_ptr<int> dev_Hash(d_particleHash);
  thrust::device_ptr<int> dev_id(d_particleid);
  thrust::sort_by_key(dev_Hash, dev_Hash + NUM, dev_id); //need to generalise this 10
  
  // --------------------- finding cell start and cell end for each cell -----------------------------

  cudaMemcpy(tnc, d_tnc, sizeint, cudaMemcpyDeviceToHost);
  int cellarrsize = *tnc * sizeof(int);
  cellStart = (int *)malloc(cellarrsize);
  cellEnd = (int *)malloc(cellarrsize);
  cudaMalloc((void **)&d_cellStart, cellarrsize); 
  cudaMalloc((void **)&d_cellEnd, cellarrsize); 
  
  InitializeCellDetails<<<*tnc/THREADS_PER_BLOCK + 1,THREADS_PER_BLOCK>>>(d_cellStart, d_cellEnd, d_tnc);
  findCellStart<<<NUM/THREADS_PER_BLOCK + 1,THREADS_PER_BLOCK>>>(d_particleHash, d_cellStart, d_cellEnd, d_NUM);
  
  // -------------------------- Creating neighbour arrays for each particle ------------------------------

  createNeighbourArraysCUDA<<<NUM/THREADS_PER_BLOCK + 1,THREADS_PER_BLOCK>>>(d_neighb, d_cellStart, d_cellEnd, d_particleHash, d_particleid, d_ncx, d_ncy, d_ncz, d_max_neighb, d_NUM);
  cudaMemcpy(h_neighb, d_neighb, sizeneighb, cudaMemcpyDeviceToHost);

  // ---------------------------- Populating neighb array ----------------------
       
  neighb_cuda = new int*[NUM+1];
  for(int i=0; i<NUM+1; i++){
    neighb_cuda[i] = new int[MAX_NEIGHB + 2];
  }
  
  for(int j=0; j<NUM; j++){
    for(int i=0; i<h_neighb[j*(MAX_NEIGHB + 1)]; i++){
      neighb_cuda[j+1][i+2] = h_neighb[j*(MAX_NEIGHB + 1) + i + 1];
    }
    neighb_cuda[j+1][1] = h_neighb[j*(MAX_NEIGHB + 1)];
  }
  
  // -------------------------- Deallocating memory ---------------------------

  cudaFree(d_particleHash);
  cudaFree(d_particleid);
  cudaFree(d_cellStart);
  cudaFree(d_cellEnd);
  cudaFree(d_x);
  cudaFree(d_y);
  cudaFree(d_z);
  cudaFree(d_Xmin);
  cudaFree(d_Xmax);
  cudaFree(d_Ymin);
  cudaFree(d_Ymax);
  cudaFree(d_Zmin);
  cudaFree(d_Zmax);
  cudaFree(d_re);
  cudaFree(d_NUM);
  cudaFree(d_tnc);
  cudaFree(d_ncx);
  cudaFree(d_ncy);
  cudaFree(d_ncz);
  cudaFree(d_neighb);
  cudaFree(d_max_neighb);
  cudaFree(d_sizeof_neighbours);

  free(h_neighb);
  free(tnc);
}

void NEIGHBOUR_serial(){

  // ------------------PARAMETERS DEFENTION -------------------------------------
  int ncx = int((Xmax - Xmin) / (re + DELTA)) + 1;     // Number of cells in x direction
  int ncy = int((Ymax - Ymin) / (re + DELTA)) + 1;     // Number of cells in y direction
  int ncz = int((Zmax - Zmin) / (re + DELTA)) + 1;     // Number of cells in z direction

  int tnc = ncx*ncy*ncz;                 // Total number of cells   
  int m, k, kmax, Cnum;

  neighb = new int*[NUM+1];
  for(int i=0; i<NUM+1; i++){
    neighb[i] = new int[MAX_NEIGHB + 2];
  }

  int *Ista, *Iend, *nc, *icell, *jcell, *kcell;
  int *ip;                             // I is sorted number of ip[I] th paricle
  Ista = new int[tnc + 1]; //this points to the index of the first element in a cell in the array ip
  Iend = new int[tnc + 1]; //index of the last element in a cell in the array ip
  nc = new int[tnc + 1];
  icell = new int[NUM + 1];
  jcell = new int[NUM + 1];
  kcell = new int[NUM + 1];
  ip = new int[NUM + 1]; //this is the main array that we are looking for, it is sorted 
  // according to cell numbers and it contains particle indices 

  //----------------- ALLOCATING PRTICLES IN CELLS --------------------------

  for (k = 1; k <= tnc; k++) //cell loop 
  {
    Ista[k] = 1;
    Iend[k] = 0;
    nc[k] = 0;
  }
  for (k = 1; k <= NUM; k++) //particle loop
  {
    icell[k] = int((x[k-1] - Xmin) / (re + DELTA)) + 1;
    jcell[k] = int((y[k-1] - Ymin) / (re + DELTA)) + 1;
    kcell[k] = int((z[k-1] - Zmin) / (re + DELTA)) + 1;

    Cnum = icell[k] + (jcell[k] - 1)*ncx + (kcell[k] - 1)*ncx*ncy;     // Cell number in which particle k located

    nc[Cnum]++;                       // Number of particle in cell Cnum
    Iend[Cnum]++;                   // Number of particle in cell Cnum 

    for (m = Iend[tnc]; m >= Iend[Cnum]; m--)
    {
      if (m>0) ip[m + 1] = ip[m];
    } //this block is there to create space at the end as and when new particles are added

    for (m = Cnum + 1; m <= tnc; m++)
    {
      Ista[m]++;
      Iend[m]++;
    }

    ip[Iend[Cnum]] = k;
  }

  //--------------- SEARCHING NEIGHBORS ----------------------------------
  int JJ, J;
  for (int I = 1; I <= NUM; I++)
  {
    k = 2;
    int row, colu, elev, m1, m2, m3, m4, m5, m6;
    if (icell[I] == 1)m1 = 0; else m1 = -1;
    if (icell[I] == ncx)m2 = 0; else m2 = +1;
    if (jcell[I] == 1)m3 = 0; else m3 = -1;
    if (jcell[I] == ncy)m4 = 0; else m4 = +1;
    if (kcell[I] == 1)m5 = 0; else m5 = -1;
    if (kcell[I] == ncz)m6 = 0; else m6 = +1;

    for (row = m1; row <= m2; row++) //could be -1 to 1 , the triple loop is basically there to find all the 9 cells around that particle, including the one in which it itself is
    {
      for (colu = m3; colu <= m4; colu++) 
      {
        for (elev = m5; elev <= m6; elev++)
        {

          Cnum = icell[I] + row + (jcell[I] - 1 + colu)*ncx + (kcell[I] - 1 + elev)*ncx*ncy;

          for (JJ = Ista[Cnum]; JJ <= Iend[Cnum]; JJ++)
          {
            J = ip[JJ]; //J is tha ACTUAL particle index 
            neighb[I][k] = J;
            k++;
          }
        }
      }
    }
    kmax = k - 2;
    neighb[I][1] = kmax; //this is the total number of neighbours, which is stored at the beginning 
  }
  //--------------------Clearing dynamic arrays ----------------------------
  delete[]Ista;
  delete[]Iend;
  delete[]nc;
  delete[]icell;
  delete[]jcell;
  delete[]kcell;
  delete[]ip;
  Ista = NULL; Iend = NULL; nc = NULL; icell = NULL; jcell = NULL; kcell = NULL, ip = NULL;
}

void neighbour_cuda_2(){

  // ------------------ variable declarations and initializations ------------------------------
  int *d_cellEnd, *d_cellStart, *d_NUM, *d_tnc, *tnc, *d_ncx, *d_ncy, *d_ncz;
  int *d_particleHash, *d_particleid;
  double *d_x, *d_y, *d_z, *d_Xmax, *d_Xmin, *d_Ymax, *d_Ymin, *d_Zmax, *d_Zmin, *d_re, *d_DELTA;

  int arrsizeint = NUM * sizeof(int);
  int sizeint = sizeof(int);
  int arrsizedouble = NUM * sizeof(double);
  int sizedouble = sizeof(double);
  
  particleHash = (int *)malloc(arrsizeint);
  particleid = (int *)malloc(arrsizeint);
  tnc = (int *)malloc(sizeint);

  cudaMalloc((void **)&d_particleHash, arrsizeint);
  cudaMalloc((void **)&d_particleid, arrsizeint); 
  
  cudaMalloc((void **)&d_x, arrsizedouble);
  cudaMalloc((void **)&d_y, arrsizedouble);
  cudaMalloc((void **)&d_z, arrsizedouble);
  cudaMalloc((void **)&d_Xmin, sizedouble);
  cudaMalloc((void **)&d_Xmax, sizedouble);
  cudaMalloc((void **)&d_Ymin, sizedouble);
  cudaMalloc((void **)&d_Ymax, sizedouble);
  cudaMalloc((void **)&d_Zmin, sizedouble);
  cudaMalloc((void **)&d_Zmax, sizedouble);
  cudaMalloc((void **)&d_re, sizedouble);
  cudaMalloc((void **)&d_DELTA, sizedouble);
  cudaMalloc((void **)&d_NUM, sizeint);
  cudaMalloc((void **)&d_tnc, sizeint);
  cudaMalloc((void **)&d_ncx, sizeint);
  cudaMalloc((void **)&d_ncy, sizeint);
  cudaMalloc((void **)&d_ncz, sizeint);

  cudaMemcpy(d_x, x, arrsizedouble, cudaMemcpyHostToDevice);
  cudaMemcpy(d_y, y, arrsizedouble, cudaMemcpyHostToDevice);
  cudaMemcpy(d_z, z, arrsizedouble, cudaMemcpyHostToDevice);
  cudaMemcpy(d_Xmin, &Xmin, sizedouble, cudaMemcpyHostToDevice);
  cudaMemcpy(d_Xmax, &Xmax, sizedouble, cudaMemcpyHostToDevice);
  cudaMemcpy(d_Ymin, &Ymin, sizedouble, cudaMemcpyHostToDevice);
  cudaMemcpy(d_Ymax, &Ymax, sizedouble, cudaMemcpyHostToDevice);
  cudaMemcpy(d_Zmin, &Zmin, sizedouble, cudaMemcpyHostToDevice);
  cudaMemcpy(d_Zmax, &Zmax, sizedouble, cudaMemcpyHostToDevice);
  cudaMemcpy(d_re, &re, sizedouble, cudaMemcpyHostToDevice);
  cudaMemcpy(d_DELTA, &DELTA, sizedouble, cudaMemcpyHostToDevice);
  cudaMemcpy(d_NUM, &NUM, sizeint, cudaMemcpyHostToDevice);

  // --------------- running the calcHash kernel ----------------------------------------
  
  calcHash<<<NUM/THREADS_PER_BLOCK + 1,THREADS_PER_BLOCK>>>(d_x, d_y, d_z, d_particleHash, d_NUM, d_Xmax, d_Xmin, d_re, d_DELTA, d_Ymin, d_Ymax, d_Zmax, d_Zmin, d_particleid, d_tnc, d_ncx, d_ncy, d_ncz);
  
  // ---------------- sorting the particleHash array -----------------------------
  
  thrust::device_ptr<int> dev_Hash(d_particleHash);
  thrust::device_ptr<int> dev_id(d_particleid);
  thrust::sort_by_key(dev_Hash, dev_Hash + NUM, dev_id); //need to generalise this 10
  
  // --------------------- finding cell start and cell end for each cell -----------------------------

  cudaMemcpy(tnc, d_tnc, sizeint, cudaMemcpyDeviceToHost);
  int cellarrsize = *tnc * sizeof(int);
  cudaMalloc((void **)&d_cellStart, cellarrsize); 
  cudaMalloc((void **)&d_cellEnd, cellarrsize); 
 
  InitializeCellDetails<<<*tnc/THREADS_PER_BLOCK + 1,THREADS_PER_BLOCK>>>(d_cellStart, d_cellEnd, d_tnc);
  findCellStart<<<NUM/THREADS_PER_BLOCK + 1,THREADS_PER_BLOCK>>>(d_particleHash, d_cellStart, d_cellEnd, d_NUM);

  // ------------------- Transferring the required arrays into global memory -----

  cudaMemcpy(particleHash, d_particleHash, arrsizeint, cudaMemcpyDeviceToHost);
  cudaMemcpy(particleid, d_particleid, arrsizeint, cudaMemcpyDeviceToHost);
  cudaMemcpy(cellStart, d_cellStart, cellarrsize, cudaMemcpyDeviceToHost);
  cudaMemcpy(cellEnd, d_cellEnd, cellarrsize, cudaMemcpyDeviceToHost);

  // -------------------------- Deallocating memory ---------------------------

  cudaFree(d_particleHash);
  cudaFree(d_particleid);
  cudaFree(d_cellStart);
  cudaFree(d_cellEnd);
  cudaFree(d_x);
  cudaFree(d_y);
  cudaFree(d_z);
  cudaFree(d_Xmin);
  cudaFree(d_Xmax);
  cudaFree(d_Ymin);
  cudaFree(d_Ymax);
  cudaFree(d_Zmin);
  cudaFree(d_Zmax);
  cudaFree(d_re);
  cudaFree(d_NUM);
  cudaFree(d_tnc);
  cudaFree(d_ncx);
  cudaFree(d_ncy);
  cudaFree(d_ncz);

  free(particleHash);
  free(particleid);
  free(cellStart);
  free(cellEnd);
  free(tnc);
}