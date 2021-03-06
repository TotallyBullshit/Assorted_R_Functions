library(compiler)
library(proxy)
library(cluster)
library(tm)
library(topicmodels)
library(mallet)
library(Matrix)
library(lda)
library(slam)
library(wordcloud)


MakeBatches <- function(vec, num.batches){
  # divides vec into num.batches
  # warning, output in not ordered according to vec
  
  batches <- vec
  batches.1 <- split(batches[ 1:(floor(length(batches)/(num.batches-1) ) * (num.batches-1)) ], 1:(num.batches-1))
  batches.1[[ num.batches ]] <- (batches.1[[(num.batches-1)]][length(batches.1[[(num.batches-1)]])] + 1):length(batches)
  batches <- batches.1
  rm(batches.1)
  
  # remove any values from batches that aren't in vec
  batches <- lapply(batches, function(x) x[ x %in% vec ])
  
  return(batches)
}

MakeSparseDTM <- function(dtm){
  # dtm is a simple triplet matrix
  dtm.sparse <- sparseMatrix(i=dtm$i, j=dtm$j, x=dtm$v, 
                             dims=c(dtm$nrow, dtm$ncol))
  
  rownames(dtm.sparse) <- Docs(dtm)
  colnames(dtm.sparse) <- Terms(dtm)
  
  return(dtm.sparse)
}


JSD<-cmpfun(function(p,q){
  
  #This calculates the Jensen Shannon Divergence for two probability vectors, p and q.
  p[p==0] <- 10^-4
  q[q==0] <- 10^-4
  
  p <- p/sum(p)
  q <- q/sum(q)
  
  m=(p+q)/2
    
  jsd <- (0.5 * sum(log(p / m) * p)) + (0.5 * sum(log(q / m) * q))
  
  return(jsd)
})


GetNN<-cmpfun(function(sim.mat,N){
  #takes in a symmetric matrix of similarities and returns a list of matrices were all entries in the similarity matrix are set to 0 except the top N similarites.
  
  diag(sim.mat)<-0
  
  tmp<-apply(sim.mat,2,function(x){
    top.N <-sort(x,decreasing=TRUE)[1:N]
    
    x[!names(x) %in% names(top.N)]<-0
    
    return(x)
  })
  
  #tmp is not symmetric; make it that way. Think of tmp as a directed adjacency matrix. We want it undirected.
  return(pmax(tmp,t(tmp))) #takes the max of two values. If both 0, then 0. if both non-zero, then they're equal and non-zero. If one is zero and one is non-zero, return the non-zero value.
})


TopicHclust <- cmpfun(function(topic.probs, dist.fun){
    require(proxy)
  
  topic.dist <- dist(topic.probs, method=dist.fun)
  
  topic.hclust <- hclust(topic.dist, method="ward")
  
  topic.names <- apply(topic.probs, 1, function(x){
    name <- names( x[ x %in% sort(x, decreasing=TRUE)[1:4]] )
    name <- paste(name, collapse=" | ")
  })
 topic.names <- paste("t.", 1:nrow(topic.probs), " | " , topic.names , sep="")
 
  topic.hclust$labels <- topic.names
  
  return( list(hclust=topic.hclust, dist=topic.dist) )
})

SilhKmed <- function( range, dist.obj){
    require(cluster)
  km <- lapply(range, function(k) pam(x=dist.obj, k=k) )
  
  silh <- lapply(km, function(clust){
    silhouette(x=clust$clustering, dist=dist.obj)
  })
  
  result <- lapply(silh, function(s){
    data.frame( s[ , c("cluster", "sil_width" ) ], stringsAsFactors=FALSE )
  })
  
  names(result) <- paste("k.", range, sep="")
  
  return(result)
}

SilhHclust <- function(range, hclust.obj, dist.obj){
    require(cluster)
  silh <- lapply(range, function(k){
    clust <- cutree(hclust.obj, k=k)
    silh <- silhouette(x=clust, dist=dist.obj)
    return(data.frame(k=k, silh=summary(silh)["avg.width"]))
  })
  
  silh <- do.call(rbind, silh)
  
  return(silh)
}

tCoherence <- cmpfun(function( topic, M, dtm.sparse ){
  require(Matrix)
  # ordered vector of most probable M terms given a topic
  terms <- names(topic)[ order(topic, decreasing=TRUE ) ][ 1:M ]
  
  # sparse subset of dtm for terms, columns ordered by decreasing probability
  dtm.t <- dtm.sparse[ , terms ]
  dtm.t[ dtm.t > 0 ] <- 1
  count.mat <- t(dtm.t) %*% dtm.t
  
  result <- sapply( 1:(ncol(count.mat) - 1), function(x){
    sum( log(count.mat[ x , (x + 1):ncol(count.mat) ] + 1) ) - length((x + 1):ncol(count.mat)) * log(count.mat[ x , x ])    
  })
  return( sum(result, na.rm=TRUE) )
})

tCoherence2 <- cmpfun(function( topic, M, dtm.sparse, pct=FALSE, num.docs=nrow(dtm.sparse) ){
  require(Matrix)
  # ordered vector of most probable M terms given a topic
  terms <- names(topic)[ order(topic, decreasing=TRUE ) ][ 1:M ]
  
  # sparse subset of dtm for terms, columns ordered by decreasing probability
  dtm.t <- dtm.sparse[ , terms ]
  dtm.t[ dtm.t > 0 ] <- 1
  count.mat <- t(dtm.t) %*% dtm.t
  
  p.mat <- count.mat / num.docs
  
  
  result <- sapply( 1:(ncol(count.mat) - 1), function(x){
    if(! pct){
        mean(p.mat[ x, (x + 1):ncol(p.mat) ]/p.mat[ x , x ] - diag(p.mat)[ (x + 1):ncol(p.mat) ], na.rm=TRUE)
    }else{
        mean( (p.mat[ x, (x + 1):ncol(p.mat) ]/p.mat[ x , x ] - diag(p.mat)[ (x + 1):ncol(p.mat) ])/diag(p.mat)[ (x + 1):ncol(p.mat) ], na.rm=TRUE ) * 100
    }
    
  })
  return( mean(result, na.rm=TRUE) )
})


tLift <- cmpfun(function( topic, M, dtm.sparse, num.docs=nrow(dtm.sparse) ){
    require(Matrix)
    # ordered vector of most probable M terms given a topic
    terms <- names(topic)[ order(topic, decreasing=TRUE ) ][ 1:M ]
    
    # sparse subset of dtm for terms, columns ordered by decreasing probability
    dtm.t <- dtm.sparse[ , terms ]
    dtm.t[ dtm.t > 0 ] <- 1
    count.mat <- t(dtm.t) %*% dtm.t
    
    result <- sapply( 1:(ncol(count.mat) - 1), function(x){
        mean( (count.mat[ x , (x + 1):ncol(count.mat) ] * count.mat)/(diag(count.mat)[ (x + 1):ncol(p.mat) ] * count.mat[ x, x ]), na.rm=TRUE)
    })
    return( mean(result, na.rm=TRUE) )
})

GetMalletFreq <- function(docs, stopwordpath){
  options(java.parameters = "-Xmx8g")
  
  mallet.instances <- mallet.import(id.array=names(docs), 
                                    text.array=docs, 
                                    token.regexp = "[a-z]+(_[a-z]+)*_*", 
                                    stoplist.file=stopwordpath
                                    )
  
  topic.model <- MalletLDA(num.topics=10, alpha.sum=50, beta=0.1) # no model is built, so these settings are irrelevant
  topic.model$loadDocuments(mallet.instances)
  word.freqs <- mallet.word.freqs(topic.model)
  
  return(word.freqs) 
}

MalletWrapper <- function(k, docs, alpha.int, beta.int, iter=2000, threads=1, stopwordpath="output/dropped.terms.txt", outfilepath="output/", return.result=FALSE){
    require(rJava)  
    require(mallet)
    
    
    
    options(java.parameters = "-Xms4g")
    options(java.parameters = "-Xmx16g")
    
    mallet.instances <- mallet.import(id.array=names(docs), 
                                      text.array=docs, 
                                      token.regexp = "[a-z]+(_[a-z]+)*_*", 
                                      stoplist.file=stopwordpath
                                      )
    
    topic.model <- MalletLDA(num.topics=k, alpha.sum=alpha.int, beta=beta.int)
    
    topic.model$loadDocuments(mallet.instances)
    
    vocabulary <- topic.model$getVocabulary()
    
    time <- proc.time()
    
    if( threads > 1 ){
      threads <- as.integer(threads)
      topic.model$model$setNumThreads(4L)
    }
	    
    topic.model$train(iter)
    
    run.time <- proc.time()-time
    
    doc.topics <- mallet.doc.topics(topic.model, smoothed = TRUE, normalized = TRUE)
    rownames(doc.topics) <- topic.model$getDocumentNames()
    colnames(doc.topics) <- paste("t.",1:ncol(doc.topics), sep="")
    
    topic.words <- mallet.topic.words(topic.model, smoothed = TRUE, normalized = TRUE)
    colnames(topic.words) <- vocabulary
    rownames(topic.words) <- paste("t.",1:nrow(topic.words), sep="")
    
    loglikelihood <- topic.model$model$modelLogLikelihood()
        
    result <- list(k=k, loglikelihood=loglikelihood, topic.terms=topic.words, doc.topics=doc.topics, alpha=topic.model$getAlpha(), beta=topic.model$model$beta, run.time=run.time)
    
    save(result, file=paste(outfilepath, "MalletOutput_k.", result$k, ".", Sys.Date(), ".RData", sep="") )
    
    # cleanup because I've been having memory issues running sequentially
    rm(mallet.instances, topic.model)
    gc()
    .jcall("java/lang/System",,"gc")
    
    if(return.result){
		print( paste( "Model Complete: runtime = ", round(run.time[3]/60,1), " minutes. See ", outfilepath, " for results.", sep="") )
        return(result)
    }else{
        return( paste( "Model Complete: runtime = ", round(run.time[3]/60,1), " minutes. See ", outfilepath, " for results.", sep="") )
    }
    
}

# remove leading/trailing/multiple spaces
  FixSpaces <- function(char.vec){
    char.vec <- gsub( "^ +", "", char.vec ) #leading
    char.vec <- gsub( " +$", "", char.vec ) #trailing
    char.vec <- gsub( " +", " ", char.vec ) #multiple to single
    return(char.vec)
  }



# counts number of documents in which terms appear and number of unique terms appearing in each document  
CheckTerms <- function(keyterms, doc.vec){
  mat <- Matrix(sapply(keyterms, function(x) as.numeric(grepl(x, doc.vec)) ), sparse=TRUE)
  rownames(mat) <- names(keyterms)
  result <- list(term.doc.freq=colSums(mat), terms.in.doc=rowSums(mat))
}

# makes some adjustments to pluralization
# WARNING: This does make mistakes for irregular words. You should check its results manually.
CorrectS <- function(term.vec){
    s.adjust <- gsub("sses$", "ss", term.vec) 
    keep.list <- s.adjust[ grepl("sis$|ss$|us$", s.adjust) | nchar(term.vec) <= 3 | grepl( "_[a-zA-Z][a-zA-Z][a-zA-Z]$", s.adjust) ]
    
    s.adjust2 <- gsub("ies$", "y", s.adjust)
    s.adjust2 <- gsub("s$", "", s.adjust2)
    
    out.list <- s.adjust2
    out.list[ s.adjust %in% keep.list ] <- s.adjust[ s.adjust %in% keep.list ]
    
    result <- data.frame(original=term.vec, adjusted=out.list, changed=term.vec!=out.list, stringsAsFactors=FALSE)
    return(result)
}

DocSSE <- cmpfun(function(doc.row, doc.name, doc.topics, topic.terms){
	require(Matrix)
	
	y <- doc.row  # y <- doc.row / sum(doc.row )
	
	yhat <- sum(doc.row ) * doc.topics[ doc.name , ] %*% topic.terms # yhat <- doc.topics[ doc.name , ] %*% topic.terms
	yhat <- yhat[ , names(y) ]
	
	result <- sum( (y-yhat)^2 )
	return(result)
})

ParallelSSE <- function(outputlist, dtm.sparse, cpus){
  # warning, only works for a specifically named and formatted input
  
  require(snowfall)
  
  sfInit(parallel=TRUE, cpus=cpus)
  sfExport(list=c("dtm.sparse", "DocSSE"))
  sfLibrary(Matrix)
  
  
  result <- sfLapply(outputlist, function(x){
    sapply(rownames(dtm.sparse), function(doc){
      DocSSE( doc.row=dtm.sparse[ doc , ], doc.name=doc, doc.topics=x$doc.topics, topic.terms=x$topic.terms ) # topic.words
    })
  })
  
  sfStop()
  return(result)
}


AggTopics <-cmpfun(function(tclust, topic.probs){
    # tclust is a vector denoting cluster assignment of topics
	# topic.progs is a matrix whose rows are topics and columns are terms
	
  result <- sapply(unique(tclust), function(x){
    tmp.probs <- topic.probs[ tclust == x , ]
    
    if(! is.null(dim(tmp.probs)) ){
      tmp.probs <- colSums(tmp.probs)
      tmp.probs <- tmp.probs/sum(tmp.probs)
    }
    
    return(tmp.probs)
  })
  
  
  colnames(result) <- unique(tclust)
  
  return(result)
})

NgramTokenizer <- function(min, max) {
  require(RWeka)
  # Function creates a function to create ngrams from a document term matrix
  # For bigrams min=max=2. For bigrams and trigrams min=2, max=3
  # Example: 
  # Bigrams <- NgramTokenizer(2, 2)
  # myDTM <- DocumentTermMatrix(myCorp, control = list(tokenize = Bigrams))
  
  
  result <- function(x) {NGramTokenizer(x, Weka_control(min = min, max = max))}
  
  return(result)
}

GetTopTerms <- function(topic.terms, M){
  # Takes topics X terms matrix and returns top M terms for each topic
  
  result <- apply(topic.terms, 1, function(x){
    names(x)[ order(x, decreasing=TRUE) ][ 1:M ]
  })
  
  return(result)
}

TmLDAWrapper <- function(dtm, k){
  # wrapper to run LDA for our pre-determined specifications from Griffiths and Steyvers 2004 (the default for topicmodels)
  
  lda <- LDA(x=dtm, 
             k=k, 
             method="Gibbs", 
             control=list(seed=1234,
                          keep=1 # keeps log likelihoods
             )
  )
  
  #   lda.posterior <- posterior(lda)
  #   names(lda.posterior) <- c("topic.probs", "doc.topics")
  l.lik <- logLik(lda)
  
  return(list(model=lda, l.lik=l.lik)) # posterior=lda.posterior, 
  
}

ExtractLdaResults_lda <- function(lda.result, docnames, likelihood=TRUE, smooth=FALSE){
  # extracts outputs from LDA model estimated with lda package by Jonathan Chang
  
  doc.topics <- t(lda.result$document_sums)
    if(smooth){ doc.topics <- doc.topics + 0.0001 }
  doc.topics <- doc.topics/rowSums(doc.topics)
  rownames(doc.topics) <- docnames
  colnames(doc.topics) <- paste("t.", 1:ncol(doc.topics), sep="" )
  
  topic.terms <- lda.result$topics
    if(smooth){ topic.terms <- topic.terms + 1/ncol(topic.terms) }
  topic.terms <- topic.terms/rowSums(topic.terms)
  rownames(topic.terms) <- colnames(doc.topics)
  
  result <- list(doc.topics=doc.topics, topic.terms=topic.terms)
  
  if(likelihood){ result$likelihood <- lda.result$log.likelihoods }
  
  return(result)
  
}

DocCosSim <- cmpfun(function(doc.row, doc.index, doc.topics, topic.terms){
	require(Matrix)
	
	y <- doc.row  # y <- doc.row / sum(doc.row )
	
	yhat <- sum(doc.row ) * doc.topics[ doc.index , ] %*% topic.terms # yhat <- doc.topics[ doc.index , ] %*% topic.terms
    
    yhat <- yhat[ , names(y) ]
	
	result <- ( t(y) %*% yhat ) / ( sqrt( t(y) %*% y ) * sqrt( t(yhat) %*% yhat ) )  # cosine similarity
	
	return(result)
})

ParallelCosSim <- function(outputlist, dtm.sparse, cpus){
    # warning, only works for a specifically named and formatted input
    # These inputs are in line with our standards
    
    require(snowfall)
    
    sfInit(parallel=TRUE, cpus=cpus)
    sfExport("outputlist")
    sfExport(c("dtm.sparse", "DocCosSim"))
    sfLibrary(Matrix)
    
    
    result <- sfLapply(outputlist, function(x){
        sapply(rownames(dtm.sparse), function(doc){
            DocCosSim( doc.row=dtm.sparse[ doc , ], doc.name=doc, doc.topics=x$doc.topics, topic.terms=x$topic.terms ) # topic.words
        })
    })
    
    sfStop()
    return(result)
}

Dtm2Docs <- cmpfun(function(dtm.sparse, parallel=FALSE, cpus=NULL){
	# function creates a corpus of text documents based on term frequencies of a document term matrix
	terms <- colnames(dtm.sparse)
    if( ! parallel ){
        result <- apply(dtm.sparse, 1, function(x){
            paste( unlist( mapply( function(x,y) rep(y, x), x, terms)), collapse=" " )
        })
    }else{
        library( snowfall )
        sfInit( parallel=TRUE, cpus=cpus )
        sfLibrary(Matrix)
        sfExport( "terms" )
        
        result <- sfApply(dtm.sparse, 1, function(x){
            paste( unlist( mapply( function(x,y) rep(y, x), x, terms)), collapse=" " )
        })
        
        sfStop()
    }
    
    gc()
    
    return(result)
})


TopicWordCloud <- function(term.freq.vec, title="", outfilepath=""){
    # Takes a numeric vector whose names are the terms we wish to display
    # Does not return a value; plots the word cloud
    df <- data.frame(term=names(term.freq.vec)[ term.freq.vec > 0],  freq=term.freq.vec[ term.freq.vec > 0])
    
    df$freq <- round(df$freq/max(df$freq) * 100)
    
    col <- c("#313695", rev(brewer.pal(4, "RdYlBu")))
    
    png( paste(outfilepath, title, ".png", sep=""), width=8, height=8, units='in', res=300)
        par(bg="#F8F8FF")
        wordcloud(words=df$term, freq=df$freq, scale=c(4, 0.5), min.freq=1, max.words=100, colors=col, random.order=FALSE)
        title(main=title, line=-2)
    dev.off()
}
